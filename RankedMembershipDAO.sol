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
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RankedMembershipDAO is Ownable2Step, Pausable, ReentrancyGuard, IERC721Receiver {
    using SafeCast for uint256;
    using Checkpoints for Checkpoints.Trace224;
    using SafeERC20 for IERC20;

    // ----------------------------
    // Constants (immutable limits for safeguards)
    // ----------------------------

    uint64 public constant INVITE_EPOCH = 100 days;

    // Bounds for configurable parameters (safety limits)
    uint64 public constant MIN_INVITE_EXPIRY = 1 hours;
    uint64 public constant MAX_INVITE_EXPIRY = 7 days;

    uint64 public constant MIN_ORDER_DELAY = 1 hours;
    uint64 public constant MAX_ORDER_DELAY = 7 days;

    uint64 public constant MIN_VOTING_PERIOD = 1 days;
    uint64 public constant MAX_VOTING_PERIOD = 30 days;

    uint16 public constant MIN_QUORUM_BPS = 500;   // 5% minimum quorum
    uint16 public constant MAX_QUORUM_BPS = 5000;  // 50% maximum quorum

    uint64 public constant MIN_EXECUTION_DELAY = 1 hours;
    uint64 public constant MAX_EXECUTION_DELAY = 7 days;

    // ----------------------------
    // Configurable Governance Parameters (can be changed via governance)
    // ----------------------------

    uint64 public inviteExpiry = 24 hours;
    uint64 public orderDelay = 24 hours;
    uint64 public votingPeriod = 7 days;
    uint16 public quorumBps = 2000; // 20% of total snapshot voting power
    uint64 public executionDelay = 24 hours; // timelock for treasury proposals

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
        // Only F or higher can invite. F=1, E=2, D=4, etc.
        // Formula: 2^(rankIndex - 1) for F+, 0 for G
        if (r < Rank.F) return 0;
        return uint16(1 << (_rankIndex(r) - _rankIndex(Rank.F)));
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
    error InvalidParameterValue();
    error ParameterOutOfBounds();
    error FundsNotAccepted();

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
        ChangeAuthority,
        ChangeVotingPeriod,
        ChangeQuorumBps,
        ChangeOrderDelay,
        ChangeInviteExpiry,
        ChangeExecutionDelay,
        BlockOrder,  // Block a pending order via general vote
        TransferERC20  // Transfer accidental ERC20 deposits
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
        uint64 newParameterValue;  // for governance parameter change proposals
        uint64 orderIdToBlock;     // for BlockOrder proposals
        address erc20Token;        // for TransferERC20 proposals
        uint256 erc20Amount;       // for TransferERC20 proposals
        address erc20Recipient;    // for TransferERC20 proposals

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
    event OrderBlockedByGovernance(uint64 indexed orderId, uint64 indexed proposalId);
    event OrderExecuted(uint64 indexed orderId);

    event ProposalCreated(uint64 indexed proposalId, ProposalType proposalType, uint32 indexed proposerId, uint32 indexed targetId, Rank rankValue, address newAuthority, uint64 startTime, uint64 endTime, uint32 snapshotBlock);
    event ParameterProposalCreated(uint64 indexed proposalId, ProposalType proposalType, uint32 indexed proposerId, uint64 newValue, uint64 startTime, uint64 endTime, uint32 snapshotBlock);
    event BlockOrderProposalCreated(uint64 indexed proposalId, uint32 indexed proposerId, uint64 indexed orderId, uint64 startTime, uint64 endTime, uint32 snapshotBlock);
    event TransferERC20ProposalCreated(uint64 indexed proposalId, uint32 indexed proposerId, address indexed token, uint256 amount, address recipient, uint64 startTime, uint64 endTime, uint32 snapshotBlock);
    event ERC20Transferred(uint64 indexed proposalId, address indexed token, address indexed recipient, uint256 amount);
    event VoteCast(uint64 indexed proposalId, uint32 indexed voterId, bool support, uint224 weight);
    event ProposalFinalized(uint64 indexed proposalId, bool succeeded, uint224 yesVotes, uint224 noVotes);

    event VotingPeriodChanged(uint64 oldValue, uint64 newValue, uint64 proposalId);
    event QuorumBpsChanged(uint16 oldValue, uint16 newValue, uint64 proposalId);
    event OrderDelayChanged(uint64 oldValue, uint64 newValue, uint64 proposalId);
    event InviteExpiryChanged(uint64 oldValue, uint64 newValue, uint64 proposalId);
    event ExecutionDelayChanged(uint64 oldValue, uint64 newValue, uint64 proposalId);

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
        uint64 expiresAt = issuedAt + inviteExpiry;

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
            executeAfter: uint64(block.timestamp + orderDelay),
            blocked: false,
            executed: false,
            blockedById: 0
        });

        emit OrderCreated(orderId, OrderType.PromoteGrant, issuerId, targetId, newRank, address(0), uint64(block.timestamp + orderDelay));
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
            executeAfter: uint64(block.timestamp + orderDelay),
            blocked: false,
            executed: false,
            blockedById: 0
        });

        emit OrderCreated(orderId, OrderType.DemoteOrder, issuerId, targetId, Rank.G, address(0), uint64(block.timestamp + orderDelay));
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
            executeAfter: uint64(block.timestamp + orderDelay),
            blocked: false,
            executed: false,
            blockedById: 0
        });

        emit OrderCreated(orderId, OrderType.AuthorityOrder, issuerId, targetId, Rank.G, newAuthority, uint64(block.timestamp + orderDelay));
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

    // ----------------------------
    // Governance: Parameter Change Proposals
    // ----------------------------

    function createProposalChangeVotingPeriod(uint64 newValue) external whenNotPaused nonReentrant returns (uint64 proposalId) {
        if (newValue < MIN_VOTING_PERIOD || newValue > MAX_VOTING_PERIOD) revert ParameterOutOfBounds();
        
        uint32 proposerId = _requireMemberAuthority(msg.sender);
        if (membersById[proposerId].rank < Rank.F) revert RankTooLow();
        _enforceProposalLimit(proposerId);

        proposalId = _createProposalFull(
            ProposalType.ChangeVotingPeriod,
            proposerId,
            0, // no target
            Rank.G, // unused
            address(0), // unused
            newValue
        );

        emit ParameterProposalCreated(proposalId, ProposalType.ChangeVotingPeriod, proposerId, newValue, uint64(block.timestamp), uint64(block.timestamp) + votingPeriod, block.number.toUint32());
    }

    function createProposalChangeQuorumBps(uint16 newValue) external whenNotPaused nonReentrant returns (uint64 proposalId) {
        if (newValue < MIN_QUORUM_BPS || newValue > MAX_QUORUM_BPS) revert ParameterOutOfBounds();
        
        uint32 proposerId = _requireMemberAuthority(msg.sender);
        if (membersById[proposerId].rank < Rank.F) revert RankTooLow();
        _enforceProposalLimit(proposerId);

        proposalId = _createProposalFull(
            ProposalType.ChangeQuorumBps,
            proposerId,
            0, // no target
            Rank.G, // unused
            address(0), // unused
            uint64(newValue)
        );

        emit ParameterProposalCreated(proposalId, ProposalType.ChangeQuorumBps, proposerId, uint64(newValue), uint64(block.timestamp), uint64(block.timestamp) + votingPeriod, block.number.toUint32());
    }

    function createProposalChangeOrderDelay(uint64 newValue) external whenNotPaused nonReentrant returns (uint64 proposalId) {
        if (newValue < MIN_ORDER_DELAY || newValue > MAX_ORDER_DELAY) revert ParameterOutOfBounds();
        
        uint32 proposerId = _requireMemberAuthority(msg.sender);
        if (membersById[proposerId].rank < Rank.F) revert RankTooLow();
        _enforceProposalLimit(proposerId);

        proposalId = _createProposalFull(
            ProposalType.ChangeOrderDelay,
            proposerId,
            0, // no target
            Rank.G, // unused
            address(0), // unused
            newValue
        );

        emit ParameterProposalCreated(proposalId, ProposalType.ChangeOrderDelay, proposerId, newValue, uint64(block.timestamp), uint64(block.timestamp) + votingPeriod, block.number.toUint32());
    }

    function createProposalChangeInviteExpiry(uint64 newValue) external whenNotPaused nonReentrant returns (uint64 proposalId) {
        if (newValue < MIN_INVITE_EXPIRY || newValue > MAX_INVITE_EXPIRY) revert ParameterOutOfBounds();
        
        uint32 proposerId = _requireMemberAuthority(msg.sender);
        if (membersById[proposerId].rank < Rank.F) revert RankTooLow();
        _enforceProposalLimit(proposerId);

        proposalId = _createProposalFull(
            ProposalType.ChangeInviteExpiry,
            proposerId,
            0, // no target
            Rank.G, // unused
            address(0), // unused
            newValue
        );

        emit ParameterProposalCreated(proposalId, ProposalType.ChangeInviteExpiry, proposerId, newValue, uint64(block.timestamp), uint64(block.timestamp) + votingPeriod, block.number.toUint32());
    }

    function createProposalChangeExecutionDelay(uint64 newValue) external whenNotPaused nonReentrant returns (uint64 proposalId) {
        if (newValue < MIN_EXECUTION_DELAY || newValue > MAX_EXECUTION_DELAY) revert ParameterOutOfBounds();
        
        uint32 proposerId = _requireMemberAuthority(msg.sender);
        if (membersById[proposerId].rank < Rank.F) revert RankTooLow();
        _enforceProposalLimit(proposerId);

        proposalId = _createProposalFull(
            ProposalType.ChangeExecutionDelay,
            proposerId,
            0, // no target
            Rank.G, // unused
            address(0), // unused
            newValue
        );

        emit ParameterProposalCreated(proposalId, ProposalType.ChangeExecutionDelay, proposerId, newValue, uint64(block.timestamp), uint64(block.timestamp) + votingPeriod, block.number.toUint32());
    }

    /// @notice Create a proposal to block a pending order via governance vote
    /// @dev This allows the DAO to block any order (including those from SSS members) through democratic vote
    /// @param orderId The ID of the pending order to block
    /// @return proposalId The ID of the newly created proposal
    function createProposalBlockOrder(uint64 orderId) external whenNotPaused nonReentrant returns (uint64 proposalId) {
        uint32 proposerId = _requireMemberAuthority(msg.sender);
        if (membersById[proposerId].rank < Rank.F) revert RankTooLow();

        // Verify the order exists and is blockable
        PendingOrder storage o = ordersById[orderId];
        if (!o.exists) revert NoPendingAction();
        if (o.blocked) revert OrderBlocked();
        if (o.executed) revert OrderNotReady();

        _enforceProposalLimit(proposerId);

        proposalId = _createProposalWithOrder(
            ProposalType.BlockOrder,
            proposerId,
            o.targetId, // store target for reference
            Rank.G, // unused
            address(0), // unused
            0, // unused
            orderId
        );

        emit BlockOrderProposalCreated(proposalId, proposerId, orderId, uint64(block.timestamp), uint64(block.timestamp) + votingPeriod, block.number.toUint32());
    }

    /// @notice Create a proposal to transfer accidentally deposited ERC20 tokens
    /// @dev This allows the DAO to recover ERC20 tokens that were sent to this contract by mistake.
    ///      Unlike ETH and NFTs which can be rejected, ERC20 transfers via `transfer()` cannot be blocked.
    /// @param token The ERC20 token contract address
    /// @param amount The amount of tokens to transfer
    /// @param recipient The address to receive the recovered tokens
    /// @return proposalId The ID of the newly created proposal
    function createProposalTransferERC20(address token, uint256 amount, address recipient) external whenNotPaused nonReentrant returns (uint64 proposalId) {
        _requireValidAddress(token);
        _requireValidAddress(recipient);
        if (amount == 0) revert InvalidParameterValue();

        uint32 proposerId = _requireMemberAuthority(msg.sender);
        if (membersById[proposerId].rank < Rank.F) revert RankTooLow();
        _enforceProposalLimit(proposerId);

        proposalId = _createProposalComplete(
            ProposalType.TransferERC20,
            proposerId,
            0, // no target member
            Rank.G, // unused
            address(0), // unused
            0, // unused
            0, // unused
            token,
            amount,
            recipient
        );

        emit TransferERC20ProposalCreated(proposalId, proposerId, token, amount, recipient, uint64(block.timestamp), uint64(block.timestamp) + votingPeriod, block.number.toUint32());
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
        return _createProposalFull(pType, proposerId, targetId, rankValue, newAuthority, 0, 0);
    }

    function _createProposalFull(
        ProposalType pType,
        uint32 proposerId,
        uint32 targetId,
        Rank rankValue,
        address newAuthority,
        uint64 newParameterValue
    ) internal returns (uint64 proposalId) {
        return _createProposalWithOrder(pType, proposerId, targetId, rankValue, newAuthority, newParameterValue, 0);
    }

    function _createProposalWithOrder(
        ProposalType pType,
        uint32 proposerId,
        uint32 targetId,
        Rank rankValue,
        address newAuthority,
        uint64 newParameterValue,
        uint64 orderIdToBlock
    ) internal returns (uint64 proposalId) {
        return _createProposalComplete(pType, proposerId, targetId, rankValue, newAuthority, newParameterValue, orderIdToBlock, address(0), 0, address(0));
    }

    function _createProposalComplete(
        ProposalType pType,
        uint32 proposerId,
        uint32 targetId,
        Rank rankValue,
        address newAuthority,
        uint64 newParameterValue,
        uint64 orderIdToBlock,
        address erc20Token,
        uint256 erc20Amount,
        address erc20Recipient
    ) internal returns (uint64 proposalId) {
        proposalId = nextProposalId++;

        uint64 start = uint64(block.timestamp);
        uint64 end = start + votingPeriod;

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
            newParameterValue: newParameterValue,
            orderIdToBlock: orderIdToBlock,
            erc20Token: erc20Token,
            erc20Amount: erc20Amount,
            erc20Recipient: erc20Recipient,
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
        uint256 required = (uint256(totalAtSnap) * quorumBps) / 10_000;
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
        // Handle BlockOrder separately since it doesn't need a member target
        if (p.proposalType == ProposalType.BlockOrder) {
            _executeBlockOrderProposal(p);
            return;
        }

        // Handle TransferERC20 proposals (recovery of accidental deposits)
        if (p.proposalType == ProposalType.TransferERC20) {
            _executeTransferERC20Proposal(p);
            return;
        }

        // Handle parameter change proposals (no target member)
        if (p.proposalType == ProposalType.ChangeVotingPeriod ||
            p.proposalType == ProposalType.ChangeQuorumBps ||
            p.proposalType == ProposalType.ChangeOrderDelay ||
            p.proposalType == ProposalType.ChangeInviteExpiry ||
            p.proposalType == ProposalType.ChangeExecutionDelay) {
            _executeParameterProposal(p);
            return;
        }

        // Member-related proposals
        uint32 targetId = p.targetId;
        if (!membersById[targetId].exists) revert InvalidTarget();

        // keep "one outstanding order" invariant: governance acts only if no pending order exists
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

    function _executeBlockOrderProposal(Proposal storage p) internal {
        uint64 orderId = p.orderIdToBlock;
        PendingOrder storage o = ordersById[orderId];
        
        // Order must exist and not already be blocked/executed
        if (!o.exists) revert NoPendingAction();
        if (o.blocked) revert OrderBlocked();
        if (o.executed) revert OrderNotReady();

        // Block the order via governance
        o.blocked = true;
        o.blockedById = 0; // 0 indicates governance blocked it

        // Unlock target
        if (pendingOrderOfTarget[o.targetId] == orderId) {
            pendingOrderOfTarget[o.targetId] = 0;
        }

        emit OrderBlockedByGovernance(orderId, p.proposalId);
    }

    function _executeTransferERC20Proposal(Proposal storage p) internal {
        address token = p.erc20Token;
        uint256 amount = p.erc20Amount;
        address recipient = p.erc20Recipient;

        // Transfer the ERC20 tokens using SafeERC20
        IERC20(token).safeTransfer(recipient, amount);

        emit ERC20Transferred(p.proposalId, token, recipient, amount);
    }

    function _executeParameterProposal(Proposal storage p) internal {
        if (p.proposalType == ProposalType.ChangeVotingPeriod) {
            uint64 oldValue = votingPeriod;
            votingPeriod = p.newParameterValue;
            emit VotingPeriodChanged(oldValue, p.newParameterValue, p.proposalId);
        } else if (p.proposalType == ProposalType.ChangeQuorumBps) {
            uint16 oldValue = quorumBps;
            quorumBps = uint16(p.newParameterValue);
            emit QuorumBpsChanged(oldValue, uint16(p.newParameterValue), p.proposalId);
        } else if (p.proposalType == ProposalType.ChangeOrderDelay) {
            uint64 oldValue = orderDelay;
            orderDelay = p.newParameterValue;
            emit OrderDelayChanged(oldValue, p.newParameterValue, p.proposalId);
        } else if (p.proposalType == ProposalType.ChangeInviteExpiry) {
            uint64 oldValue = inviteExpiry;
            inviteExpiry = p.newParameterValue;
            emit InviteExpiryChanged(oldValue, p.newParameterValue, p.proposalId);
        } else if (p.proposalType == ProposalType.ChangeExecutionDelay) {
            uint64 oldValue = executionDelay;
            executionDelay = p.newParameterValue;
            emit ExecutionDelayChanged(oldValue, p.newParameterValue, p.proposalId);
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

    // ----------------------------
    // Fund Rejection & ERC-721 Receiver
    // ----------------------------
    // This contract is NOT a recipient of funds. ETH transfers are rejected via receive().
    // NFT transfers via safeTransferFrom are rejected by returning an invalid selector.
    // ERC20 transfers via transfer() CANNOT be blocked - use TransferERC20 proposals to recover.

    /// @notice Rejects any ETH transfers sent directly to this contract.
    receive() external payable {
        revert FundsNotAccepted();
    }

    /// @notice Implements IERC721Receiver to reject NFT transfers via safeTransferFrom.
    /// @dev Returns an invalid selector to cause the safeTransferFrom to revert.
    ///      Note: Direct transferFrom() calls cannot be blocked as they don't call this function.
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert FundsNotAccepted();
    }

    /// @notice Rejects any calls to undefined functions.
    fallback() external payable {
        revert FundsNotAccepted();
    }
}
