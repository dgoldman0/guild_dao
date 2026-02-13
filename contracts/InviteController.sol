// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title InviteController — Membership invite system for the Guild DAO.
/// @author Guild DAO
/// @notice Manages invite issuance (per-epoch allowance by rank), acceptance
///         (creates a new G-rank member), and reclaim (returns allowance after
///         expiry).  Registered as `inviteController` on GuildController.
/// @dev    Member creation flows through GuildController.addMember() → DAO.

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RankedMembershipDAO} from "./RankedMembershipDAO.sol";
import {GuildController} from "./GuildController.sol";

contract InviteController is ReentrancyGuard {

    // ================================================================
    //                        DAO REFERENCE
    // ================================================================

    RankedMembershipDAO public immutable dao;
    GuildController public immutable guildCtrl;

    // ================================================================
    //                          ERRORS
    // ================================================================

    error NotMember();
    error AlreadyMember();
    error InvalidAddress();
    error NotEnoughRank();
    error InviteNotFound();
    error InviteExpired();
    error InviteAlreadyClaimed();
    error InviteAlreadyReclaimed();
    error InviteNotYetExpired();
    error InvalidTarget();
    error NotAuthorizedAuthority();

    // ================================================================
    //                         INVITES
    // ================================================================

    struct Invite {
        bool exists;
        uint64 inviteId;
        uint32 issuerId;
        address to;
        uint64 issuedAt;
        uint64 expiresAt;
        uint64 epoch;
        bool claimed;
        bool reclaimed;
    }

    uint64 public nextInviteId = 1;
    mapping(uint64 => Invite) public invitesById;

    // issuerId => epoch => invitesUsed
    mapping(uint32 => mapping(uint64 => uint16)) public invitesUsedByEpoch;

    // ================================================================
    //                          EVENTS
    // ================================================================

    event InviteIssued(uint64 indexed inviteId, uint32 indexed issuerId, address indexed to, uint64 expiresAt, uint64 epoch);
    event InviteClaimed(uint64 indexed inviteId, uint32 indexed newMemberId, address indexed authority);
    event InviteReclaimed(uint64 indexed inviteId, uint32 indexed issuerId);

    // ================================================================
    //                        CONSTRUCTOR
    // ================================================================

    constructor(address daoAddress, address guildControllerAddress) {
        if (daoAddress == address(0)) revert InvalidAddress();
        if (guildControllerAddress == address(0)) revert InvalidAddress();
        dao = RankedMembershipDAO(payable(daoAddress));
        guildCtrl = GuildController(guildControllerAddress);
    }

    // ================================================================
    //                    INTERNAL HELPERS
    // ================================================================

    function _requireMember(address who) internal view returns (uint32 memberId, RankedMembershipDAO.Rank rank) {
        memberId = dao.memberIdByAuthority(who);
        if (memberId == 0) revert NotMember();
        (bool exists,, RankedMembershipDAO.Rank r, address authority,) = dao.membersById(memberId);
        if (!exists || authority != who) revert NotMember();
        rank = r;
    }

    function _requireMemberAuthority(address who) internal view returns (uint32 memberId) {
        (memberId,) = _requireMember(who);
    }

    function _currentEpoch() internal view returns (uint64) {
        return uint64(block.timestamp / dao.EPOCH());
    }

    // ================================================================
    //                     INVITE FUNCTIONS
    // ================================================================

    /// @notice Issue an invite to `to`.  Caller must be F+ with remaining epoch allowance.
    /// @param to The wallet address of the person being invited.
    /// @return inviteId The newly created invite ID.
    function issueInvite(address to) external nonReentrant returns (uint64 inviteId) {
        if (to == address(0)) revert InvalidAddress();

        (uint32 issuerId, RankedMembershipDAO.Rank issuerRank) = _requireMember(msg.sender);

        // prevent inviting an existing authority
        if (dao.memberIdByAuthority(to) != 0) revert AlreadyMember();

        uint64 epoch = _currentEpoch();
        uint16 used = invitesUsedByEpoch[issuerId][epoch];
        uint16 allowance = dao.inviteAllowanceOfRank(issuerRank);
        if (used >= allowance) revert NotEnoughRank();

        invitesUsedByEpoch[issuerId][epoch] = used + 1;

        inviteId = nextInviteId++;
        uint64 issuedAt = uint64(block.timestamp);
        uint64 expiresAt = issuedAt + dao.inviteExpiry();

        invitesById[inviteId] = Invite({
            exists: true,
            inviteId: inviteId,
            issuerId: issuerId,
            to: to,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            epoch: epoch,
            claimed: false,
            reclaimed: false
        });

        emit InviteIssued(inviteId, issuerId, to, expiresAt, epoch);
    }

    /// @notice Accept a pending invite.  Creates a new G-rank member.
    /// @dev Must be called by the `to` address before the invite expires.
    /// @param inviteId The invite to accept.
    /// @return newMemberId The ID of the newly created member.
    function acceptInvite(uint64 inviteId) external nonReentrant returns (uint32 newMemberId) {
        Invite storage inv = invitesById[inviteId];
        if (!inv.exists) revert InviteNotFound();
        if (inv.claimed) revert InviteAlreadyClaimed();
        if (inv.reclaimed) revert InviteAlreadyReclaimed();
        if (block.timestamp > inv.expiresAt) revert InviteExpired();
        if (inv.to != msg.sender) revert InvalidAddress();
        if (dao.memberIdByAuthority(msg.sender) != 0) revert AlreadyMember();

        inv.claimed = true;

        // Create member via GuildController → DAO (inviteController is authorized)
        newMemberId = guildCtrl.addMember(msg.sender);

        emit InviteClaimed(inviteId, newMemberId, msg.sender);
    }

    /// @notice Reclaim an expired, unclaimed invite to recover the issuer's allowance.
    /// @dev Only the original issuer can reclaim.
    /// @param inviteId The expired invite to reclaim.
    function reclaimExpiredInvite(uint64 inviteId) external nonReentrant {
        Invite storage inv = invitesById[inviteId];
        if (!inv.exists) revert InviteNotFound();
        if (inv.claimed) revert InviteAlreadyClaimed();
        if (inv.reclaimed) revert InviteAlreadyReclaimed();
        if (block.timestamp <= inv.expiresAt) revert InviteNotYetExpired();

        uint32 issuerId = _requireMemberAuthority(msg.sender);
        if (issuerId != inv.issuerId) revert InvalidTarget();

        inv.reclaimed = true;

        uint16 used = invitesUsedByEpoch[issuerId][inv.epoch];
        if (used > 0) {
            invitesUsedByEpoch[issuerId][inv.epoch] = used - 1;
        }

        emit InviteReclaimed(inviteId, issuerId);
    }

    // ================================================================
    //                      VIEW FUNCTIONS
    // ================================================================

    /// @notice Retrieve a full invite struct.
    /// @param inviteId The invite to look up.
    function getInvite(uint64 inviteId) external view returns (Invite memory) {
        return invitesById[inviteId];
    }
}
