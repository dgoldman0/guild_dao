// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    Membership-controlled DAO (ranked members, invites, orders w/ timelock+veto, and ranked snapshot voting).

    OpenZeppelin deps (v5+ recommended):
      - @openzeppelin/contracts/access/Ownable2Step.sol
      - @openzeppelin/contracts/security/Pausable.sol
      - @openzeppelin/contracts/security/ReentrancyGuard.sol
      - @openzeppelin/contracts/utils/math/SafeCast.sol
      - @openzeppelin/contracts/utils/structs/Checkpoints.sol

    Notes / assumptions (easy to tweak):
      - Rank enum is increasing power: G (lowest) ... SSS (highest). Voting power = 2^rankIndex.
      - Invite allowance per 100-day epoch is also 2^rankIndex (G=1, F=2, ..., SSS=512).
      - Governance proposals: fixed voting period, simple majority + quorum (bps of total snapshot power).
      - “One outstanding grant/order at once” is enforced per *target member* (and also blocks self-authority-change while pending).
*/

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

contract RankedMembershipDAO is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeCast for uint256;
    using Checkpoints for Checkpoints.Trace224;

    // ----------------------------
    // Constants / Parameters
    // ----------------------------

    uint64 public constant INVITE_EPOCH = 100 days;
    uint64 public constant INVITE_EXPIRY = 24 hours;

    uint64 public constant ORDER_DELAY = 24 hours;

    uint64 public constant VOTING_PERIOD = 7 days;
    uint16 public constant QUORUM_BPS = 2000; // 20% of total snapshot voting power

    // ----------------------------
    // Ranks
    // ----------------------------

    enum Rank {
        G,   // 0
        F,   // 1
        E,   // 2
        D,   // 3
        C,   // 4
        B,   // 5
        A,   // 6
        S,   // 7
        SS,  // 8
        SSS  // 9
    }

    function _rankIndex(Rank r) internal pure returns (uint8) {
        return uint8(r);
    }

    function votingPowerOfRank(Rank r) public pure returns (uint224) {
        // 2^rankIndex, with rankIndex in [0..9]
        return uint224(1 << _rankIndex(r));
    }

    function inviteAllowanceOfRank(Rank r) public pure returns (uint16) {
        // Same doubling model as voting power.
        return uint16(1 << _rankIndex(r));
    }

    function proposalLimitOfRank(Rank r) public pure returns (uint8) {
        // Spec says: F can propose; limit increases by 1 each rank.
        // Implemented linearly: F=1, E=2, D=3, C=4, ... SSS=9.
        if (r < Rank.F) return 0;
        return uint8(1 + (_rankIndex(r) - _rankIndex(Rank.F)));
    }

    // ----------------------------
    // Errors
    // ----------------------------

    error NotMember();
    error AlreadyMember();
    error InvalidAddress();
    error InvalidRank();
    error RankTooLow();
    error PendingActionExists();
    error NoPendingAction();
    error NotAuthorizedAuthority();
    error InviteExpired();
    error InviteNotFound();
    error InviteAlreadyClaimed();
    error InviteAlreadyReclaimed();
    error InviteNotYetExpired();
    error ProposalNotFound();
    error ProposalNotActive();
    error ProposalEnded();
    error ProposalAlreadyFinalized();
    error AlreadyVoted();
    error QuorumNotMet();
    error NotEnoughRank();
    error InvalidPromotion();
    error InvalidDemotion();
    error InvalidTarget();
    error TooManyActiveProposals();
    error VetoNotAllowed();
    error OrderNotReady();
    error OrderBlocked();
    error OrderWrongType();
    error BootstrapAlreadyFinalized();

    // ----------------------------
    // Membership
    // ----------------------------

    struct Member {
        bool exists;
        uint32 id;
        Rank rank;
        address authority;
        uint64 joinedAt;
    }

    uint32 public nextMemberId = 1; // start at 1 (0 means "none")
    mapping(uint32 => Member) public membersById;
    mapping(address => uint32) public memberIdByAuthority;

    // voting power snapshot checkpoints
    mapping(uint32 => Checkpoints.Trace224) private _memberPower;
    Checkpoints.Trace224 private _totalPower;

    // ----------------------------
    // Bootstrap controls (optional, but standard)
    // ----------------------------

    bool public bootstrapFinalized;

    // ----------------------------
    // Invites
    // ----------------------------

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

    // issuerId => epoch => invitesUsed (claimed + currently outstanding not reclaimed)
    mapping(uint32 => mapping(uint64 => uint16)) public invitesUsedByEpoch;

    // ----------------------------
    // Timelocked Orders (Promotion / Demotion / Authority change on behalf)
    // ----------------------------

    enum OrderType {
        PromoteGrant,      // target must accept AFTER 24h
        DemoteOrder,       // executes AFTER 24h
        AuthorityOrder     // executes AFTER 24h
    }

    struct PendingOrder {
        bool exists;
        uint64 orderId;
        OrderType orderType;

        uint32 issuerId;
        Rank issuerRankAtCreation;

        uint32 targetId;

        // payload
        Rank newRank;          // for PromoteGrant
        address newAuthority;  // for AuthorityOrder

        uint64 createdAt;
        uint64 executeAfter;

        bool blocked;
        bool executed;
        uint32 blockedById;
    }

    uint64 public nextOrderId = 1;
    mapping(uint64 => PendingOrder) public ordersById;

    // Enforce: a target member can have only one outstanding order at a time
    mapping(uint32 => uint64) public pendingOrderOfTarget;

    // ----------------------------
    // Governance Proposals
    // ----------------------------

    enum ProposalType {
        GrantRank,
        DemoteRank,
        ChangeAuthority
    }

    struct Proposal {
        bool exists;
        uint64 proposalId;
        ProposalType proposalType;

        uint32 proposerId;
        uint32 targetId;

        // payload (one of these used depending on proposalType)
        Rank rankValue;
        address newAuthority;

        uint32 snapshotBlock;
        uint64 startTime;
        uint64 endTime;

        uint224 yesVotes;
        uint224 noVotes;

        bool finalized;
        bool succeeded;
    }

    uint64 public nextProposalId = 1;
    mapping(uint64 => Proposal) public proposalsById;

    // proposalId => memberId => voted
    mapping(uint64 => mapping(uint32 => bool)) public hasVoted;

    // proposerId => active proposals count (created but not finalized)
    mapping(uint32 => uint16) public activeProposalsOf;

    // ----------------------------
    // Events
    // ----------------------------

    event BootstrapMember(uint32 indexed memberId, address indexed authority, Rank rank);
    event BootstrapFinalized();

    event MemberJoined(uint32 indexed memberId, address indexed authority, Rank rank);
    event AuthorityChanged(uint32 indexed memberId, address indexed oldAuthority, address indexed newAuthority, uint32 byMemberId, bool viaGovernance);
    event RankChanged(uint32 indexed memberId, Rank oldRank, Rank newRank, uint32 byMemberId, bool viaGovernance);

    event InviteIssued(uint64 indexed inviteId, uint32 indexed issuerId, address indexed to, uint64 expiresAt, uint64 epoch);
    event InviteClaimed(uint64 indexed inviteId, uint32 indexed newMemberId, address indexed authority);
    event InviteReclaimed(uint64 indexed inviteId, uint32 indexed issuerId);

    event OrderCreated(uint64 indexed orderId, OrderType orderType, uint32 indexed issuerId, uint32 indexed targetId, Rank newRank, address newAuthority, uint64 executeAfter);
    event OrderBlocked(uint64 indexed orderId, uint32 indexed blockerId);
    event OrderExecuted(uint64 indexed orderId);

    event ProposalCreated(uint64 indexed proposalId, ProposalType proposalType, uint32 indexed proposerId, uint32 indexed targetId, Rank rankValue, address newAuthority, uint64 startTime, uint64 endTime, uint32 snapshotBlock);
    event VoteCast(uint64 indexed proposalId, uint32 indexed voterId, bool support, uint224 weight);
    event ProposalFinalized(uint64 indexed proposalId, bool succeeded, uint224 yesVotes, uint224 noVotes);

    // ----------------------------
    // Constructor (seed initial SSS member)
    // ----------------------------

    constructor() Ownable2Step(msg.sender) {
        _bootstrapMember(msg.sender, Rank.SSS);
    }

    // ----------------------------
    // Modifiers / Internal helpers
    // ----------------------------

    function _requireMemberAuthority(address who) internal view returns (uint32 memberId) {
        memberId = memberIdByAuthority[who];
        if (memberId == 0 || !membersById[memberId].exists) revert NotMember();
        if (membersById[memberId].authority != who) revert NotAuthorizedAuthority();
    }

    function _requireValidAddress(address a) internal pure {
        if (a == address(0)) revert InvalidAddress();
    }

    function _requireNoPendingOnTarget(uint32 targetId) internal view {
        if (pendingOrderOfTarget[targetId] != 0) revert PendingActionExists();
    }

    function _currentEpoch() internal view returns (uint64) {
        return uint64(block.timestamp / INVITE_EPOCH);
    }

    function totalVotingPower() public view returns (uint224) {
        return _totalPower.latest();
    }

    function totalVotingPowerAt(uint32 blockNumber) public view returns (uint224) {
        return _totalPower.upperLookupRecent(blockNumber);
    }

    function votingPowerOfMember(uint32 memberId) public view returns (uint224) {
        return _memberPower[memberId].latest();
    }

    function votingPowerOfMemberAt(uint32 memberId, uint32 blockNumber) public view returns (uint224) {
        return _memberPower[memberId].upperLookupRecent(blockNumber);
    }

    function _writeMemberPower(uint32 memberId, uint224 newPower) internal {
        _memberPower[memberId].push(block.number.toUint32(), newPower);
    }

    function _writeTotalPower(uint224 newTotal) internal {
        _totalPower.push(block.number.toUint32(), newTotal);
    }

    function _setRank(uint32 memberId, Rank newRank, uint32 byMemberId, bool viaGovernance) internal {
        Member storage m = membersById[memberId];
        if (!m.exists) revert InvalidTarget();

        Rank old = m.rank;
        if (old == newRank) return;

        uint224 oldP = votingPowerOfRank(old);
        uint224 newP = votingPowerOfRank(newRank);

        m.rank = newRank;

        // update power checkpoints
        _writeMemberPower(memberId, newP);

        // update total power checkpoint
        uint224 total = totalVotingPower();
        if (newP > oldP) {
            total += (newP - oldP);
        } else {
            total -= (oldP - newP);
        }
        _writeTotalPower(total);

        emit RankChanged(memberId, old, newRank, byMemberId, viaGovernance);
    }

    function _setAuthority(uint32 memberId, address newAuthority, uint32 byMemberId, bool viaGovernance) internal {
        _requireValidAddress(newAuthority);

        Member storage m = membersById[memberId];
        if (!m.exists) revert InvalidTarget();

        // ensure new authority unused
        if (memberIdByAuthority[newAuthority] != 0) revert AlreadyMember();

        address old = m.authority;

        // clear old mapping, set new mapping
        memberIdByAuthority[old] = 0;
        memberIdByAuthority[newAuthority] = memberId;
        m.authority = newAuthority;

        emit AuthorityChanged(memberId, old, newAuthority, byMemberId, viaGovernance);
    }

    function _bootstrapMember(address authority, Rank rank) internal {
        if (bootstrapFinalized) revert BootstrapAlreadyFinalized();
        _requireValidAddress(authority);
        if (memberIdByAuthority[authority] != 0) revert AlreadyMember();

        uint32 id = nextMemberId++;
        membersById[id] = Member({
            exists: true,
            id: id,
            rank: rank,
            authority: authority,
            joinedAt: uint64(block.timestamp)
        });
        memberIdByAuthority[authority] = id;

        uint224 p = votingPowerOfRank(rank);
        _writeMemberPower(id, p);

        uint224 total = totalVotingPower();
        total += p;
        _writeTotalPower(total);

        emit BootstrapMember(id, authority, rank);
    }

    // ----------------------------
    // Admin safety (standard)
    // ----------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Optional: add initial members before turning off bootstrap forever.
    function bootstrapAddMember(address authority, Rank rank) external onlyOwner {
        _bootstrapMember(authority, rank);
    }

    function finalizeBootstrap() external onlyOwner {
        bootstrapFinalized = true;
        emit BootstrapFinalized();
    }

    // ----------------------------
    // Invites
    // ----------------------------

    function issueInvite(address to) external whenNotPaused nonReentrant returns (uint64 inviteId) {
        _requireValidAddress(to);

        uint32 issuerId = _requireMemberAuthority(msg.sender);
        Member storage issuer = membersById[issuerId];

        // prevent inviting an existing authority
        if (memberIdByAuthority[to] != 0) revert AlreadyMember();

        uint64 epoch = _currentEpoch();
        uint16 used = invitesUsedByEpoch[issuerId][epoch];
        uint16 allowance = inviteAllowanceOfRank(issuer.rank);

        if (used >= allowance) revert NotEnoughRank();

        // reserve a slot immediately; reclaimed on expiry
        invitesUsedByEpoch[issuerId][epoch] = used + 1;

        inviteId = nextInviteId++;
        uint64 issuedAt = uint64(block.timestamp);
        uint64 expiresAt = issuedAt + INVITE_EXPIRY;

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

    function acceptInvite(uint64 inviteId) external whenNotPaused nonReentrant returns (uint32 newMemberId) {
        Invite storage inv = invitesById[inviteId];
        if (!inv.exists) revert InviteNotFound();
        if (inv.claimed) revert InviteAlreadyClaimed();
        if (inv.reclaimed) revert InviteAlreadyReclaimed();
        if (block.timestamp > inv.expiresAt) revert InviteExpired();

        if (inv.to != msg.sender) revert InvalidAddress();
        if (memberIdByAuthority[msg.sender] != 0) revert AlreadyMember();

        inv.claimed = true;

        // create member at rank G
        newMemberId = nextMemberId++;
        membersById[newMemberId] = Member({
            exists: true,
            id: newMemberId,
            rank: Rank.G,
            authority: msg.sender,
            joinedAt: uint64(block.timestamp)
        });
        memberIdByAuthority[msg.sender] = newMemberId;

        uint224 p = votingPowerOfRank(Rank.G);
        _writeMemberPower(newMemberId, p);

        uint224 total = totalVotingPower();
        total += p;
        _writeTotalPower(total);

        emit MemberJoined(newMemberId, msg.sender, Rank.G);
        emit InviteClaimed(inviteId, newMemberId, msg.sender);
    }

    function reclaimExpiredInvite(uint64 inviteId) external whenNotPaused nonReentrant {
        Invite storage inv = invitesById[inviteId];
        if (!inv.exists) revert InviteNotFound();
        if (inv.claimed) revert InviteAlreadyClaimed();
        if (inv.reclaimed) revert InviteAlreadyReclaimed();
        if (block.timestamp <= inv.expiresAt) revert InviteNotYetExpired();

        uint32 issuerId = _requireMemberAuthority(msg.sender);
        if (issuerId != inv.issuerId) revert InvalidTarget();

        inv.reclaimed = true;

        // restore the reserved slot for that epoch
        uint16 used = invitesUsedByEpoch[issuerId][inv.epoch];
        if (used > 0) {
            invitesUsedByEpoch[issuerId][inv.epoch] = used - 1;
        }

        emit InviteReclaimed(inviteId, issuerId);
    }

    // ----------------------------
    // Self authority change (immediate)
    // ----------------------------

    function changeMyAuthority(address newAuthority) external whenNotPaused nonReentrant {
        uint32 memberId = _requireMemberAuthority(msg.sender);
        _requireNoPendingOnTarget(memberId); // keep the “one outstanding order” invariant clean
        _setAuthority(memberId, newAuthority, memberId, false);
    }

    // ----------------------------
    // Timelocked Orders: promote / demote / authority recovery
    // ----------------------------

    function issuePromotionGrant(uint32 targetId, Rank newRank) external whenNotPaused nonReentrant returns (uint64 orderId) {
        uint32 issuerId = _requireMemberAuthority(msg.sender);

        if (!membersById[targetId].exists) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);

        Member storage issuer = membersById[issuerId];
        Member storage target = membersById[targetId];

        // must be a true promotion
        if (newRank <= target.rank) revert InvalidPromotion();

        uint8 issuerIdx = _rankIndex(issuer.rank);
        if (issuerIdx < 2) revert InvalidPromotion();

        // newRank must be <= issuerRank - 2
        uint8 maxIdx = issuerIdx - 2;
        if (_rankIndex(newRank) > maxIdx) revert InvalidPromotion();

        // lock target with a pending order
        orderId = nextOrderId++;
        pendingOrderOfTarget[targetId] = orderId;

        ordersById[orderId] = PendingOrder({
            exists: true,
            orderId: orderId,
            orderType: OrderType.PromoteGrant,
            issuerId: issuerId,
            issuerRankAtCreation: issuer.rank,
            targetId: targetId,
            newRank: newRank,
            newAuthority: address(0),
            createdAt: uint64(block.timestamp),
            executeAfter: uint64(block.timestamp + ORDER_DELAY),
            blocked: false,
            executed: false,
            blockedById: 0
        });

        emit OrderCreated(orderId, OrderType.PromoteGrant, issuerId, targetId, newRank, address(0), uint64(block.timestamp + ORDER_DELAY));
    }

    function issueDemotionOrder(uint32 targetId) external whenNotPaused nonReentrant returns (uint64 orderId) {
        uint32 issuerId = _requireMemberAuthority(msg.sender);

        if (!membersById[targetId].exists) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);

        Member storage issuer = membersById[issuerId];
        Member storage target = membersById[targetId];

        // issuer must be >= target + 2 ranks
        if (_rankIndex(issuer.rank) < _rankIndex(target.rank) + 2) revert InvalidDemotion();

        // target can't go below G, but order is still allowed; execution clamps
        orderId = nextOrderId++;
        pendingOrderOfTarget[targetId] = orderId;

        ordersById[orderId] = PendingOrder({
            exists: true,
            orderId: orderId,
            orderType: OrderType.DemoteOrder,
            issuerId: issuerId,
            issuerRankAtCreation: issuer.rank,
            targetId: targetId,
            newRank: Rank.G, // unused for demote (computed at execute)
            newAuthority: address(0),
            createdAt: uint64(block.timestamp),
            executeAfter: uint64(block.timestamp + ORDER_DELAY),
            blocked: false,
            executed: false,
            blockedById: 0
        });

        emit OrderCreated(orderId, OrderType.DemoteOrder, issuerId, targetId, Rank.G, address(0), uint64(block.timestamp + ORDER_DELAY));
    }

    function issueAuthorityOrder(uint32 targetId, address newAuthority) external whenNotPaused nonReentrant returns (uint64 orderId) {
        uint32 issuerId = _requireMemberAuthority(msg.sender);

        if (!membersById[targetId].exists) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);

        _requireValidAddress(newAuthority);
        if (memberIdByAuthority[newAuthority] != 0) revert AlreadyMember();

        Member storage issuer = membersById[issuerId];
        Member storage target = membersById[targetId];

        // issuer must be >= target + 2 ranks
        if (_rankIndex(issuer.rank) < _rankIndex(target.rank) + 2) revert InvalidTarget();

        orderId = nextOrderId++;
        pendingOrderOfTarget[targetId] = orderId;

        ordersById[orderId] = PendingOrder({
            exists: true,
            orderId: orderId,
            orderType: OrderType.AuthorityOrder,
            issuerId: issuerId,
            issuerRankAtCreation: issuer.rank,
            targetId: targetId,
            newRank: Rank.G, // unused
            newAuthority: newAuthority,
            createdAt: uint64(block.timestamp),
            executeAfter: uint64(block.timestamp + ORDER_DELAY),
            blocked: false,
            executed: false,
            blockedById: 0
        });

        emit OrderCreated(orderId, OrderType.AuthorityOrder, issuerId, targetId, Rank.G, newAuthority, uint64(block.timestamp + ORDER_DELAY));
    }

    function blockOrder(uint64 orderId) external whenNotPaused nonReentrant {
        uint32 blockerId = _requireMemberAuthority(msg.sender);

        PendingOrder storage o = ordersById[orderId];
        if (!o.exists) revert NoPendingAction();
        if (o.executed) revert OrderNotReady();
        if (o.blocked) revert OrderBlocked();
        if (block.timestamp >= o.executeAfter) revert OrderNotReady();

        // veto requires blocker rank >= issuerRankAtCreation + 2
        uint8 issuerIdx = _rankIndex(o.issuerRankAtCreation);
        uint8 blockerIdx = _rankIndex(membersById[blockerId].rank);

        if (blockerIdx < issuerIdx + 2) revert VetoNotAllowed();

        o.blocked = true;
        o.blockedById = blockerId;

        // unlock target
        if (pendingOrderOfTarget[o.targetId] == orderId) {
            pendingOrderOfTarget[o.targetId] = 0;
        }

        emit OrderBlocked(orderId, blockerId);
    }

    // Promotion grants must be accepted by the target authority, after 24 hours.
    function acceptPromotionGrant(uint64 orderId) external whenNotPaused nonReentrant {
        PendingOrder storage o = ordersById[orderId];
        if (!o.exists) revert NoPendingAction();
        if (o.orderType != OrderType.PromoteGrant) revert OrderWrongType();
        if (o.blocked) revert OrderBlocked();
        if (o.executed) revert OrderNotReady();
        if (block.timestamp < o.executeAfter) revert OrderNotReady();

        uint32 targetId = o.targetId;
        // only current target authority can accept
        uint32 callerId = _requireMemberAuthority(msg.sender);
        if (callerId != targetId) revert InvalidTarget();

        // apply promotion (must still be a promotion)
        if (o.newRank <= membersById[targetId].rank) revert InvalidPromotion();
        _setRank(targetId, o.newRank, callerId, false);

        o.executed = true;

        // unlock target
        if (pendingOrderOfTarget[targetId] == orderId) {
            pendingOrderOfTarget[targetId] = 0;
        }

        emit OrderExecuted(orderId);
    }

    // Demotion / Authority orders execute after 24 hours (anyone can execute).
    function executeOrder(uint64 orderId) external whenNotPaused nonReentrant {
        PendingOrder storage o = ordersById[orderId];
        if (!o.exists) revert NoPendingAction();
        if (o.executed) revert OrderNotReady();
        if (o.blocked) revert OrderBlocked();
        if (block.timestamp < o.executeAfter) revert OrderNotReady();

        uint32 targetId = o.targetId;

        if (o.orderType == OrderType.DemoteOrder) {
            // demote by exactly one step, not below G
            Rank cur = membersById[targetId].rank;
            if (cur > Rank.G) {
                Rank newRank = Rank(uint8(cur) - 1);
                // byMemberId is issuer (for attribution); viaGovernance=false
                _setRank(targetId, newRank, o.issuerId, false);
            }
        } else if (o.orderType == OrderType.AuthorityOrder) {
            // ensure still unused at execution time
            if (memberIdByAuthority[o.newAuthority] != 0) revert AlreadyMember();
            _setAuthority(targetId, o.newAuthority, o.issuerId, false);
        } else {
            revert OrderWrongType();
        }

        o.executed = true;

        // unlock target
        if (pendingOrderOfTarget[targetId] == orderId) {
            pendingOrderOfTarget[targetId] = 0;
        }

        emit OrderExecuted(orderId);
    }

    // ----------------------------
    // Governance: create proposal
    // ----------------------------

    function createProposalGrantRank(uint32 targetId, Rank newRank) external whenNotPaused nonReentrant returns (uint64 proposalId) {
        uint32 proposerId = _requireMemberAuthority(msg.sender);
        if (membersById[proposerId].rank < Rank.F) revert RankTooLow();

        if (!membersById[targetId].exists) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);

        // must be an upgrade
        if (newRank <= membersById[targetId].rank) revert InvalidRank();

        _enforceProposalLimit(proposerId);

        proposalId = _createProposal(
            ProposalType.GrantRank,
            proposerId,
            targetId,
            newRank,
            address(0)
        );
    }

    function createProposalDemoteRank(uint32 targetId, Rank newRank) external whenNotPaused nonReentrant returns (uint64 proposalId) {
        uint32 proposerId = _requireMemberAuthority(msg.sender);
        if (membersById[proposerId].rank < Rank.F) revert RankTooLow();

        if (!membersById[targetId].exists) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);

        // must be a demotion
        if (newRank >= membersById[targetId].rank) revert InvalidRank();

        _enforceProposalLimit(proposerId);

        proposalId = _createProposal(
            ProposalType.DemoteRank,
            proposerId,
            targetId,
            newRank,
            address(0)
        );
    }

    function createProposalChangeAuthority(uint32 targetId, address newAuthority) external whenNotPaused nonReentrant returns (uint64 proposalId) {
        uint32 proposerId = _requireMemberAuthority(msg.sender);
        if (membersById[proposerId].rank < Rank.F) revert RankTooLow();

        if (!membersById[targetId].exists) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);

        _requireValidAddress(newAuthority);
        if (memberIdByAuthority[newAuthority] != 0) revert AlreadyMember();

        _enforceProposalLimit(proposerId);

        proposalId = _createProposal(
            ProposalType.ChangeAuthority,
            proposerId,
            targetId,
            Rank.G,
            newAuthority
        );
    }

    function _enforceProposalLimit(uint32 proposerId) internal view {
        uint8 limit = proposalLimitOfRank(membersById[proposerId].rank);
        if (limit == 0) revert RankTooLow();
        if (activeProposalsOf[proposerId] >= limit) revert TooManyActiveProposals();
    }

    function _createProposal(
        ProposalType pType,
        uint32 proposerId,
        uint32 targetId,
        Rank rankValue,
        address newAuthority
    ) internal returns (uint64 proposalId) {
        proposalId = nextProposalId++;

        uint64 start = uint64(block.timestamp);
        uint64 end = start + VOTING_PERIOD;

        // Snapshot at current block
        uint32 snap = block.number.toUint32();

        proposalsById[proposalId] = Proposal({
            exists: true,
            proposalId: proposalId,
            proposalType: pType,
            proposerId: proposerId,
            targetId: targetId,
            rankValue: rankValue,
            newAuthority: newAuthority,
            snapshotBlock: snap,
            startTime: start,
            endTime: end,
            yesVotes: 0,
            noVotes: 0,
            finalized: false,
            succeeded: false
        });

        activeProposalsOf[proposerId] += 1;

        emit ProposalCreated(proposalId, pType, proposerId, targetId, rankValue, newAuthority, start, end, snap);
    }

    // ----------------------------
    // Governance: voting (snapshot power)
    // ----------------------------

    function castVote(uint64 proposalId, bool support) external whenNotPaused nonReentrant {
        Proposal storage p = proposalsById[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.finalized) revert ProposalAlreadyFinalized();
        if (block.timestamp < p.startTime) revert ProposalNotActive();
        if (block.timestamp > p.endTime) revert ProposalEnded();

        uint32 voterId = _requireMemberAuthority(msg.sender);
        if (hasVoted[proposalId][voterId]) revert AlreadyVoted();
        hasVoted[proposalId][voterId] = true;

        uint224 weight = votingPowerOfMemberAt(voterId, p.snapshotBlock);

        if (support) {
            p.yesVotes += weight;
        } else {
            p.noVotes += weight;
        }

        emit VoteCast(proposalId, voterId, support, weight);
    }

    // Anyone can finalize after endTime. If quorum+majority met, executes immediately.
    function finalizeProposal(uint64 proposalId) external whenNotPaused nonReentrant {
        Proposal storage p = proposalsById[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.finalized) revert ProposalAlreadyFinalized();
        if (block.timestamp <= p.endTime) revert ProposalNotReady();

        p.finalized = true;

        // decrement active proposal count for proposer
        if (activeProposalsOf[p.proposerId] > 0) {
            activeProposalsOf[p.proposerId] -= 1;
        }

        uint224 totalAtSnap = totalVotingPowerAt(p.snapshotBlock);
        uint224 votesCast = p.yesVotes + p.noVotes;

        // quorum check
        uint256 required = (uint256(totalAtSnap) * QUORUM_BPS) / 10_000;
        if (votesCast < required) {
            p.succeeded = false;
            emit ProposalFinalized(proposalId, false, p.yesVotes, p.noVotes);
            return;
        }

        // simple majority
        if (p.yesVotes <= p.noVotes) {
            p.succeeded = false;
            emit ProposalFinalized(proposalId, false, p.yesVotes, p.noVotes);
            return;
        }

        // execute
        p.succeeded = true;
        _executeProposal(p);

        emit ProposalFinalized(proposalId, true, p.yesVotes, p.noVotes);
    }

    function _executeProposal(Proposal storage p) internal {
        uint32 targetId = p.targetId;
        if (!membersById[targetId].exists) revert InvalidTarget();

        // keep “one outstanding order” invariant: governance acts only if no pending order exists
        if (pendingOrderOfTarget[targetId] != 0) revert PendingActionExists();

        if (p.proposalType == ProposalType.GrantRank) {
            if (p.rankValue <= membersById[targetId].rank) revert InvalidRank();
            _setRank(targetId, p.rankValue, p.proposerId, true);
        } else if (p.proposalType == ProposalType.DemoteRank) {
            if (p.rankValue >= membersById[targetId].rank) revert InvalidRank();
            _setRank(targetId, p.rankValue, p.proposerId, true);
        } else if (p.proposalType == ProposalType.ChangeAuthority) {
            if (memberIdByAuthority[p.newAuthority] != 0) revert AlreadyMember();
            _setAuthority(targetId, p.newAuthority, p.proposerId, true);
        } else {
            revert();
        }
    }

    // ----------------------------
    // View helpers
    // ----------------------------

    function myMemberId() external view returns (uint32) {
        return memberIdByAuthority[msg.sender];
    }

    function getMember(uint32 memberId) external view returns (Member memory) {
        return membersById[memberId];
    }

    function getInvite(uint64 inviteId) external view returns (Invite memory) {
        return invitesById[inviteId];
    }

    function getOrder(uint64 orderId) external view returns (PendingOrder memory) {
        return ordersById[orderId];
    }

    function getProposal(uint64 proposalId) external view returns (Proposal memory) {
        return proposalsById[proposalId];
    }
}
