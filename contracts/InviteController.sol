// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    InviteController — Membership invite system for the RankedMembershipDAO.

    Extracted from GovernanceController to keep each contract under the
    EIP-170 bytecode size limit (24 576 bytes).

    Manages:
      - Invite issuance (per-epoch allowance by rank)
      - Invite acceptance (creates new G-rank member via DAO)
      - Invite reclaim (return allowance after expiry)

    This contract is set as the `inviteController` on the DAO, giving it
    authority to call addMember().
*/

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RankedMembershipDAO} from "./RankedMembershipDAO.sol";

contract InviteController is ReentrancyGuard {

    // ================================================================
    //                        DAO REFERENCE
    // ================================================================

    RankedMembershipDAO public immutable dao;

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

    constructor(address daoAddress) {
        if (daoAddress == address(0)) revert InvalidAddress();
        dao = RankedMembershipDAO(payable(daoAddress));
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

    function acceptInvite(uint64 inviteId) external nonReentrant returns (uint32 newMemberId) {
        Invite storage inv = invitesById[inviteId];
        if (!inv.exists) revert InviteNotFound();
        if (inv.claimed) revert InviteAlreadyClaimed();
        if (inv.reclaimed) revert InviteAlreadyReclaimed();
        if (block.timestamp > inv.expiresAt) revert InviteExpired();
        if (inv.to != msg.sender) revert InvalidAddress();
        if (dao.memberIdByAuthority(msg.sender) != 0) revert AlreadyMember();

        inv.claimed = true;

        // Create member via DAO (inviteController is authorized for addMember)
        newMemberId = dao.addMember(msg.sender);

        emit InviteClaimed(inviteId, newMemberId, msg.sender);
    }

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

    function getInvite(uint64 inviteId) external view returns (Invite memory) {
        return invitesById[inviteId];
    }
}
