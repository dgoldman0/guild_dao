// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    GovernanceController — Governance logic for the RankedMembershipDAO.

    Holds all stateful governance features:
      - Invite system (issue, accept, reclaim)
      - Timelocked orders (promote, demote, authority change) with veto/block
      - Governance proposals (rank change, authority change, parameter change,
        order blocking, ERC20 recovery)
      - Voting (snapshot-based)
      - Proposal finalization and execution

    This contract is set as the `controller` on the DAO, giving it exclusive
    authority to call setRank(), setAuthority(), addMember(), and the
    governance parameter setters.
*/

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {RankedMembershipDAO} from "./RankedMembershipDAO.sol";

contract GovernanceController is ReentrancyGuard {
    using SafeCast for uint256;

    // ================================================================
    //                        DAO REFERENCE
    // ================================================================

    RankedMembershipDAO public immutable dao;

    // Convenience alias for Rank
    type Rank is uint8;

    // ================================================================
    //                          ERRORS
    // ================================================================

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
    error NotEnoughRank();
    error InvalidPromotion();
    error InvalidDemotion();
    error InvalidTarget();
    error TooManyActiveProposals();
    error VetoNotAllowed();
    error OrderNotReady();
    error OrderIsBlocked();
    error OrderWrongType();
    error OrderAlreadyRescinded();
    error TooManyActiveOrders();
    error InvalidParameterValue();
    error ParameterOutOfBounds();

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
    //                    TIMELOCKED ORDERS
    // ================================================================

    enum OrderType {
        PromoteGrant,      // target must accept AFTER delay
        DemoteOrder,       // executes AFTER delay
        AuthorityOrder     // executes AFTER delay
    }

    struct PendingOrder {
        bool exists;
        uint64 orderId;
        OrderType orderType;
        uint32 issuerId;
        RankedMembershipDAO.Rank issuerRankAtCreation;
        uint32 targetId;
        RankedMembershipDAO.Rank newRank;
        address newAuthority;
        uint64 createdAt;
        uint64 executeAfter;
        bool blocked;
        bool executed;
        uint32 blockedById;
    }

    uint64 public nextOrderId = 1;
    mapping(uint64 => PendingOrder) public ordersById;

    // target member => outstanding order id (one at a time)
    mapping(uint32 => uint64) public pendingOrderOfTarget;

    // issuer member => number of currently active (unresolved) orders
    mapping(uint32 => uint16) public activeOrdersOf;

    // ================================================================
    //                   GOVERNANCE PROPOSALS
    // ================================================================

    enum ProposalType {
        GrantRank,
        DemoteRank,
        ChangeAuthority,
        ChangeVotingPeriod,
        ChangeQuorumBps,
        ChangeOrderDelay,
        ChangeInviteExpiry,
        ChangeExecutionDelay,
        BlockOrder,
        TransferERC20,
        ResetBootstrapFee
    }

    struct Proposal {
        bool exists;
        uint64 proposalId;
        ProposalType proposalType;
        uint32 proposerId;
        uint32 targetId;

        // Payload fields (used depending on proposalType)
        RankedMembershipDAO.Rank rankValue;
        address addressValue;       // newAuthority, erc20Token, erc20Recipient
        uint64 parameterValue;      // for parameter changes
        uint64 orderIdToBlock;      // for BlockOrder
        address erc20Token;         // for TransferERC20
        uint256 erc20Amount;        // for TransferERC20
        address erc20Recipient;     // for TransferERC20

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
    mapping(uint64 => mapping(uint32 => bool)) public hasVoted;
    mapping(uint32 => uint16) public activeProposalsOf;

    // ================================================================
    //                          EVENTS
    // ================================================================

    // Invite events
    event InviteIssued(uint64 indexed inviteId, uint32 indexed issuerId, address indexed to, uint64 expiresAt, uint64 epoch);
    event InviteClaimed(uint64 indexed inviteId, uint32 indexed newMemberId, address indexed authority);
    event InviteReclaimed(uint64 indexed inviteId, uint32 indexed issuerId);

    // Order events
    event OrderCreated(uint64 indexed orderId, OrderType orderType, uint32 indexed issuerId, uint32 indexed targetId, RankedMembershipDAO.Rank newRank, address newAuthority, uint64 executeAfter);
    event OrderBlocked(uint64 indexed orderId, uint32 indexed blockerId);
    event OrderBlockedByGovernance(uint64 indexed orderId, uint64 indexed proposalId);
    event OrderExecuted(uint64 indexed orderId);
    event OrderRescinded(uint64 indexed orderId, uint32 indexed issuerId);

    // Proposal events
    event ProposalCreated(uint64 indexed proposalId, ProposalType proposalType, uint32 indexed proposerId, uint32 indexed targetId);
    event VoteCast(uint64 indexed proposalId, uint32 indexed voterId, bool support, uint224 weight);
    event ProposalFinalized(uint64 indexed proposalId, bool succeeded, uint224 yesVotes, uint224 noVotes);

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

    function _rankIndex(RankedMembershipDAO.Rank r) internal pure returns (uint8) {
        return uint8(r);
    }

    function _requireNoPendingOnTarget(uint32 targetId) internal view {
        if (pendingOrderOfTarget[targetId] != 0) revert PendingActionExists();
    }

    function _currentEpoch() internal view returns (uint64) {
        return uint64(block.timestamp / dao.EPOCH());
    }

    function _enforceOrderLimit(uint32 issuerId, RankedMembershipDAO.Rank issuerRank) internal view {
        uint8 limit = dao.orderLimitOfRank(issuerRank);
        if (limit == 0) revert RankTooLow();
        if (activeOrdersOf[issuerId] >= limit) revert TooManyActiveOrders();
    }

    function _decrementActiveOrders(uint32 issuerId) internal {
        if (activeOrdersOf[issuerId] > 0) {
            activeOrdersOf[issuerId] -= 1;
        }
    }

    function _enforceProposalLimit(uint32 proposerId) internal view {
        (, RankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        uint8 limit = dao.proposalLimitOfRank(rank);
        if (limit == 0) revert RankTooLow();
        if (activeProposalsOf[proposerId] >= limit) revert TooManyActiveProposals();
    }

    function _getMemberRank(uint32 memberId) internal view returns (RankedMembershipDAO.Rank) {
        (bool exists,, RankedMembershipDAO.Rank r,,) = dao.membersById(memberId);
        if (!exists) revert InvalidTarget();
        return r;
    }

    function _memberExists(uint32 memberId) internal view returns (bool) {
        (bool exists,,,,) = dao.membersById(memberId);
        return exists;
    }

    // ================================================================
    //                         INVITES
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

        // Create member via DAO
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
    //               TIMELOCKED ORDERS
    // ================================================================

    function issuePromotionGrant(uint32 targetId, RankedMembershipDAO.Rank newRank)
        external
        nonReentrant
        returns (uint64 orderId)
    {
        uint32 issuerId = _requireMemberAuthority(msg.sender);
        if (!_memberExists(targetId)) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);

        RankedMembershipDAO.Rank issuerRank = _getMemberRank(issuerId);
        RankedMembershipDAO.Rank targetRank = _getMemberRank(targetId);

        // must be a true promotion
        if (_rankIndex(newRank) <= _rankIndex(targetRank)) revert InvalidPromotion();

        uint8 issuerIdx = _rankIndex(issuerRank);
        if (issuerIdx < 2) revert InvalidPromotion();

        // newRank must be <= issuerRank - 2
        if (_rankIndex(newRank) > issuerIdx - 2) revert InvalidPromotion();

        _enforceOrderLimit(issuerId, issuerRank);

        orderId = nextOrderId++;
        pendingOrderOfTarget[targetId] = orderId;
        activeOrdersOf[issuerId] += 1;

        ordersById[orderId] = PendingOrder({
            exists: true,
            orderId: orderId,
            orderType: OrderType.PromoteGrant,
            issuerId: issuerId,
            issuerRankAtCreation: issuerRank,
            targetId: targetId,
            newRank: newRank,
            newAuthority: address(0),
            createdAt: uint64(block.timestamp),
            executeAfter: uint64(block.timestamp) + dao.orderDelay(),
            blocked: false,
            executed: false,
            blockedById: 0
        });

        emit OrderCreated(orderId, OrderType.PromoteGrant, issuerId, targetId, newRank, address(0), uint64(block.timestamp) + dao.orderDelay());
    }

    function issueDemotionOrder(uint32 targetId)
        external
        nonReentrant
        returns (uint64 orderId)
    {
        uint32 issuerId = _requireMemberAuthority(msg.sender);
        if (!_memberExists(targetId)) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);

        RankedMembershipDAO.Rank issuerRank = _getMemberRank(issuerId);
        RankedMembershipDAO.Rank targetRank = _getMemberRank(targetId);

        // issuer must be >= target + 2 ranks
        if (_rankIndex(issuerRank) < _rankIndex(targetRank) + 2) revert InvalidDemotion();

        _enforceOrderLimit(issuerId, issuerRank);

        orderId = nextOrderId++;
        pendingOrderOfTarget[targetId] = orderId;
        activeOrdersOf[issuerId] += 1;

        ordersById[orderId] = PendingOrder({
            exists: true,
            orderId: orderId,
            orderType: OrderType.DemoteOrder,
            issuerId: issuerId,
            issuerRankAtCreation: issuerRank,
            targetId: targetId,
            newRank: RankedMembershipDAO.Rank(0), // unused
            newAuthority: address(0),
            createdAt: uint64(block.timestamp),
            executeAfter: uint64(block.timestamp) + dao.orderDelay(),
            blocked: false,
            executed: false,
            blockedById: 0
        });

        emit OrderCreated(orderId, OrderType.DemoteOrder, issuerId, targetId, RankedMembershipDAO.Rank(0), address(0), uint64(block.timestamp) + dao.orderDelay());
    }

    function issueAuthorityOrder(uint32 targetId, address newAuthority)
        external
        nonReentrant
        returns (uint64 orderId)
    {
        uint32 issuerId = _requireMemberAuthority(msg.sender);
        if (!_memberExists(targetId)) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);
        if (newAuthority == address(0)) revert InvalidAddress();
        if (dao.memberIdByAuthority(newAuthority) != 0) revert AlreadyMember();

        RankedMembershipDAO.Rank issuerRank = _getMemberRank(issuerId);
        RankedMembershipDAO.Rank targetRank = _getMemberRank(targetId);

        // issuer must be >= target + 2 ranks
        if (_rankIndex(issuerRank) < _rankIndex(targetRank) + 2) revert InvalidTarget();

        _enforceOrderLimit(issuerId, issuerRank);

        orderId = nextOrderId++;
        pendingOrderOfTarget[targetId] = orderId;
        activeOrdersOf[issuerId] += 1;

        ordersById[orderId] = PendingOrder({
            exists: true,
            orderId: orderId,
            orderType: OrderType.AuthorityOrder,
            issuerId: issuerId,
            issuerRankAtCreation: issuerRank,
            targetId: targetId,
            newRank: RankedMembershipDAO.Rank(0), // unused
            newAuthority: newAuthority,
            createdAt: uint64(block.timestamp),
            executeAfter: uint64(block.timestamp) + dao.orderDelay(),
            blocked: false,
            executed: false,
            blockedById: 0
        });

        emit OrderCreated(orderId, OrderType.AuthorityOrder, issuerId, targetId, RankedMembershipDAO.Rank(0), newAuthority, uint64(block.timestamp) + dao.orderDelay());
    }

    function blockOrder(uint64 orderId) external nonReentrant {
        uint32 blockerId = _requireMemberAuthority(msg.sender);

        PendingOrder storage o = ordersById[orderId];
        if (!o.exists) revert NoPendingAction();
        if (o.executed) revert OrderNotReady();
        if (o.blocked) revert OrderIsBlocked();
        if (block.timestamp >= o.executeAfter) revert OrderNotReady();

        // veto requires blocker rank >= issuerRankAtCreation + 2
        uint8 issuerIdx = _rankIndex(o.issuerRankAtCreation);
        RankedMembershipDAO.Rank blockerRank = _getMemberRank(blockerId);
        uint8 blockerIdx = _rankIndex(blockerRank);

        if (blockerIdx < issuerIdx + 2) revert VetoNotAllowed();

        o.blocked = true;
        o.blockedById = blockerId;
        _decrementActiveOrders(o.issuerId);

        if (pendingOrderOfTarget[o.targetId] == orderId) {
            pendingOrderOfTarget[o.targetId] = 0;
        }

        emit OrderBlocked(orderId, blockerId);
    }

    function rescindOrder(uint64 orderId) external nonReentrant {
        uint32 callerId = _requireMemberAuthority(msg.sender);

        PendingOrder storage o = ordersById[orderId];
        if (!o.exists) revert NoPendingAction();
        if (o.issuerId != callerId) revert InvalidTarget();
        if (o.executed) revert OrderNotReady();
        if (o.blocked) revert OrderIsBlocked();

        o.blocked = true;          // treat rescind as a self-block
        o.blockedById = callerId;
        _decrementActiveOrders(callerId);

        if (pendingOrderOfTarget[o.targetId] == orderId) {
            pendingOrderOfTarget[o.targetId] = 0;
        }

        emit OrderRescinded(orderId, callerId);
    }

    function acceptPromotionGrant(uint64 orderId) external nonReentrant {
        PendingOrder storage o = ordersById[orderId];
        if (!o.exists) revert NoPendingAction();
        if (o.orderType != OrderType.PromoteGrant) revert OrderWrongType();
        if (o.blocked) revert OrderIsBlocked();
        if (o.executed) revert OrderNotReady();
        if (block.timestamp < o.executeAfter) revert OrderNotReady();

        uint32 targetId = o.targetId;
        uint32 callerId = _requireMemberAuthority(msg.sender);
        if (callerId != targetId) revert InvalidTarget();

        RankedMembershipDAO.Rank targetRank = _getMemberRank(targetId);
        if (_rankIndex(o.newRank) <= _rankIndex(targetRank)) revert InvalidPromotion();

        dao.setRank(targetId, o.newRank, callerId, false);

        o.executed = true;
        _decrementActiveOrders(o.issuerId);
        if (pendingOrderOfTarget[targetId] == orderId) {
            pendingOrderOfTarget[targetId] = 0;
        }

        emit OrderExecuted(orderId);
    }

    function executeOrder(uint64 orderId) external nonReentrant {
        PendingOrder storage o = ordersById[orderId];
        if (!o.exists) revert NoPendingAction();
        if (o.executed) revert OrderNotReady();
        if (o.blocked) revert OrderIsBlocked();
        if (block.timestamp < o.executeAfter) revert OrderNotReady();

        uint32 targetId = o.targetId;

        if (o.orderType == OrderType.DemoteOrder) {
            RankedMembershipDAO.Rank cur = _getMemberRank(targetId);
            if (_rankIndex(cur) > 0) {
                RankedMembershipDAO.Rank newRank = RankedMembershipDAO.Rank(uint8(cur) - 1);
                dao.setRank(targetId, newRank, o.issuerId, false);
            }
        } else if (o.orderType == OrderType.AuthorityOrder) {
            if (dao.memberIdByAuthority(o.newAuthority) != 0) revert AlreadyMember();
            dao.setAuthority(targetId, o.newAuthority, o.issuerId, false);
        } else {
            revert OrderWrongType();
        }

        o.executed = true;
        _decrementActiveOrders(o.issuerId);
        if (pendingOrderOfTarget[targetId] == orderId) {
            pendingOrderOfTarget[targetId] = 0;
        }

        emit OrderExecuted(orderId);
    }

    // ================================================================
    //               GOVERNANCE PROPOSALS: CREATION
    // ================================================================

    function createProposalGrantRank(uint32 targetId, RankedMembershipDAO.Rank newRank)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        (uint32 proposerId, RankedMembershipDAO.Rank proposerRank) = _requireMember(msg.sender);
        if (_rankIndex(proposerRank) < _rankIndex(RankedMembershipDAO.Rank.F)) revert RankTooLow();

        if (!_memberExists(targetId)) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);

        RankedMembershipDAO.Rank targetRank = _getMemberRank(targetId);
        if (_rankIndex(newRank) <= _rankIndex(targetRank)) revert InvalidRank();

        _enforceProposalLimit(proposerId);
        proposalId = _createProposal(ProposalType.GrantRank, proposerId, targetId, newRank, address(0), 0, 0, address(0), 0, address(0));
    }

    function createProposalDemoteRank(uint32 targetId, RankedMembershipDAO.Rank newRank)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        (uint32 proposerId, RankedMembershipDAO.Rank proposerRank) = _requireMember(msg.sender);
        if (_rankIndex(proposerRank) < _rankIndex(RankedMembershipDAO.Rank.F)) revert RankTooLow();

        if (!_memberExists(targetId)) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);

        RankedMembershipDAO.Rank targetRank = _getMemberRank(targetId);
        if (_rankIndex(newRank) >= _rankIndex(targetRank)) revert InvalidRank();

        _enforceProposalLimit(proposerId);
        proposalId = _createProposal(ProposalType.DemoteRank, proposerId, targetId, newRank, address(0), 0, 0, address(0), 0, address(0));
    }

    function createProposalChangeAuthority(uint32 targetId, address newAuthority)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        (uint32 proposerId, RankedMembershipDAO.Rank proposerRank) = _requireMember(msg.sender);
        if (_rankIndex(proposerRank) < _rankIndex(RankedMembershipDAO.Rank.F)) revert RankTooLow();

        if (!_memberExists(targetId)) revert InvalidTarget();
        _requireNoPendingOnTarget(targetId);
        if (newAuthority == address(0)) revert InvalidAddress();
        if (dao.memberIdByAuthority(newAuthority) != 0) revert AlreadyMember();

        _enforceProposalLimit(proposerId);
        proposalId = _createProposal(ProposalType.ChangeAuthority, proposerId, targetId, RankedMembershipDAO.Rank(0), newAuthority, 0, 0, address(0), 0, address(0));
    }

    // --- Parameter change proposals (unified) ---

    function createProposalChangeParameter(ProposalType pType, uint64 newValue) external nonReentrant returns (uint64 proposalId) {
        if (pType == ProposalType.ChangeVotingPeriod) {
            if (newValue < dao.MIN_VOTING_PERIOD() || newValue > dao.MAX_VOTING_PERIOD()) revert ParameterOutOfBounds();
        } else if (pType == ProposalType.ChangeQuorumBps) {
            if (newValue < dao.MIN_QUORUM_BPS() || newValue > dao.MAX_QUORUM_BPS()) revert ParameterOutOfBounds();
        } else if (pType == ProposalType.ChangeOrderDelay) {
            if (newValue < dao.MIN_ORDER_DELAY() || newValue > dao.MAX_ORDER_DELAY()) revert ParameterOutOfBounds();
        } else if (pType == ProposalType.ChangeInviteExpiry) {
            if (newValue < dao.MIN_INVITE_EXPIRY() || newValue > dao.MAX_INVITE_EXPIRY()) revert ParameterOutOfBounds();
        } else if (pType == ProposalType.ChangeExecutionDelay) {
            if (newValue < dao.MIN_EXECUTION_DELAY() || newValue > dao.MAX_EXECUTION_DELAY()) revert ParameterOutOfBounds();
        } else {
            revert InvalidParameterValue();
        }

        (uint32 proposerId,) = _requireMember(msg.sender);
        _enforceProposalLimit(proposerId);
        proposalId = _createProposal(pType, proposerId, 0, RankedMembershipDAO.Rank(0), address(0), newValue, 0, address(0), 0, address(0));
    }

    // --- BlockOrder and TransferERC20 proposals ---

    function createProposalBlockOrder(uint64 orderId) external nonReentrant returns (uint64 proposalId) {
        (uint32 proposerId, RankedMembershipDAO.Rank proposerRank) = _requireMember(msg.sender);
        if (_rankIndex(proposerRank) < _rankIndex(RankedMembershipDAO.Rank.F)) revert RankTooLow();

        PendingOrder storage o = ordersById[orderId];
        if (!o.exists) revert NoPendingAction();
        if (o.blocked) revert OrderIsBlocked();
        if (o.executed) revert OrderNotReady();

        _enforceProposalLimit(proposerId);
        proposalId = _createProposal(ProposalType.BlockOrder, proposerId, o.targetId, RankedMembershipDAO.Rank(0), address(0), 0, orderId, address(0), 0, address(0));
    }

    function createProposalTransferERC20(address token, uint256 amount, address recipient)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidParameterValue();

        (uint32 proposerId, RankedMembershipDAO.Rank proposerRank) = _requireMember(msg.sender);
        if (_rankIndex(proposerRank) < _rankIndex(RankedMembershipDAO.Rank.F)) revert RankTooLow();
        _enforceProposalLimit(proposerId);

        proposalId = _createProposal(ProposalType.TransferERC20, proposerId, 0, RankedMembershipDAO.Rank(0), address(0), 0, 0, token, amount, recipient);
    }

    /// @notice Create a proposal to convert a bootstrap member to fee-paying status.
    ///         The member's feePaidUntil will be reset from type(uint64).max to now + EPOCH.
    function createProposalResetBootstrapFee(uint32 targetMemberId) external nonReentrant returns (uint64 proposalId) {
        if (!_memberExists(targetMemberId)) revert InvalidTarget();
        if (dao.feePaidUntil(targetMemberId) != type(uint64).max) revert InvalidTarget();

        (uint32 proposerId, RankedMembershipDAO.Rank proposerRank) = _requireMember(msg.sender);
        if (_rankIndex(proposerRank) < _rankIndex(RankedMembershipDAO.Rank.F)) revert RankTooLow();
        _enforceProposalLimit(proposerId);

        proposalId = _createProposal(ProposalType.ResetBootstrapFee, proposerId, targetMemberId, RankedMembershipDAO.Rank(0), address(0), 0, 0, address(0), 0, address(0));
    }

    // ================================================================
    //              GOVERNANCE: VOTING
    // ================================================================

    function castVote(uint64 proposalId, bool support) external nonReentrant {
        Proposal storage p = proposalsById[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.finalized) revert ProposalAlreadyFinalized();
        if (block.timestamp < p.startTime) revert ProposalNotActive();
        if (block.timestamp > p.endTime) revert ProposalEnded();

        uint32 voterId = _requireMemberAuthority(msg.sender);
        if (hasVoted[proposalId][voterId]) revert AlreadyVoted();
        hasVoted[proposalId][voterId] = true;

        uint224 weight = dao.votingPowerOfMemberAt(voterId, p.snapshotBlock);

        if (support) {
            p.yesVotes += weight;
        } else {
            p.noVotes += weight;
        }

        emit VoteCast(proposalId, voterId, support, weight);
    }

    // ================================================================
    //         GOVERNANCE: FINALIZATION & EXECUTION
    // ================================================================

    function finalizeProposal(uint64 proposalId) external nonReentrant {
        Proposal storage p = proposalsById[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.finalized) revert ProposalAlreadyFinalized();
        if (block.timestamp <= p.endTime) revert ProposalEnded();

        p.finalized = true;

        if (activeProposalsOf[p.proposerId] > 0) {
            activeProposalsOf[p.proposerId] -= 1;
        }

        uint224 totalAtSnap = dao.totalVotingPowerAt(p.snapshotBlock);
        uint224 votesCast = p.yesVotes + p.noVotes;

        uint256 required = (uint256(totalAtSnap) * dao.quorumBps()) / 10_000;
        if (votesCast < required) {
            p.succeeded = false;
            emit ProposalFinalized(proposalId, false, p.yesVotes, p.noVotes);
            return;
        }

        if (p.yesVotes <= p.noVotes) {
            p.succeeded = false;
            emit ProposalFinalized(proposalId, false, p.yesVotes, p.noVotes);
            return;
        }

        p.succeeded = true;
        _executeProposal(p);

        emit ProposalFinalized(proposalId, true, p.yesVotes, p.noVotes);
    }

    function _executeProposal(Proposal storage p) internal {
        if (p.proposalType == ProposalType.BlockOrder) {
            _executeBlockOrder(p);
            return;
        }

        if (p.proposalType == ProposalType.TransferERC20) {
            dao.transferERC20(p.erc20Token, p.erc20Recipient, p.erc20Amount);
            return;
        }

        // Parameter changes
        if (p.proposalType == ProposalType.ChangeVotingPeriod) {
            dao.setVotingPeriod(p.parameterValue);
            return;
        }
        if (p.proposalType == ProposalType.ChangeQuorumBps) {
            dao.setQuorumBps(uint16(p.parameterValue));
            return;
        }
        if (p.proposalType == ProposalType.ChangeOrderDelay) {
            dao.setOrderDelay(p.parameterValue);
            return;
        }
        if (p.proposalType == ProposalType.ChangeInviteExpiry) {
            dao.setInviteExpiry(p.parameterValue);
            return;
        }
        if (p.proposalType == ProposalType.ChangeExecutionDelay) {
            dao.setExecutionDelay(p.parameterValue);
            return;
        }

        if (p.proposalType == ProposalType.ResetBootstrapFee) {
            dao.resetBootstrapFee(p.targetId);
            return;
        }

        // Member-related proposals
        uint32 targetId = p.targetId;
        if (!_memberExists(targetId)) revert InvalidTarget();
        if (pendingOrderOfTarget[targetId] != 0) revert PendingActionExists();

        if (p.proposalType == ProposalType.GrantRank) {
            RankedMembershipDAO.Rank targetRank = _getMemberRank(targetId);
            if (_rankIndex(p.rankValue) <= _rankIndex(targetRank)) revert InvalidRank();
            dao.setRank(targetId, p.rankValue, p.proposerId, true);
        } else if (p.proposalType == ProposalType.DemoteRank) {
            RankedMembershipDAO.Rank targetRank = _getMemberRank(targetId);
            if (_rankIndex(p.rankValue) >= _rankIndex(targetRank)) revert InvalidRank();
            dao.setRank(targetId, p.rankValue, p.proposerId, true);
        } else if (p.proposalType == ProposalType.ChangeAuthority) {
            if (dao.memberIdByAuthority(p.addressValue) != 0) revert AlreadyMember();
            dao.setAuthority(targetId, p.addressValue, p.proposerId, true);
        }
    }

    function _executeBlockOrder(Proposal storage p) internal {
        uint64 orderId = p.orderIdToBlock;
        PendingOrder storage o = ordersById[orderId];

        if (!o.exists) revert NoPendingAction();
        if (o.blocked) revert OrderIsBlocked();
        if (o.executed) revert OrderNotReady();

        o.blocked = true;
        o.blockedById = 0; // governance blocked
        _decrementActiveOrders(o.issuerId);

        if (pendingOrderOfTarget[o.targetId] == orderId) {
            pendingOrderOfTarget[o.targetId] = 0;
        }

        emit OrderBlockedByGovernance(orderId, p.proposalId);
    }

    // ================================================================
    //              INTERNAL: PROPOSAL CREATION
    // ================================================================

    function _createProposal(
        ProposalType pType,
        uint32 proposerId,
        uint32 targetId,
        RankedMembershipDAO.Rank rankValue,
        address addressValue,
        uint64 parameterValue,
        uint64 orderIdToBlock,
        address erc20Token,
        uint256 erc20Amount,
        address erc20Recipient
    ) internal returns (uint64 proposalId) {
        proposalId = nextProposalId++;

        uint64 start = uint64(block.timestamp);
        uint64 end = start + dao.votingPeriod();
        uint32 snap = block.number.toUint32();

        proposalsById[proposalId] = Proposal({
            exists: true,
            proposalId: proposalId,
            proposalType: pType,
            proposerId: proposerId,
            targetId: targetId,
            rankValue: rankValue,
            addressValue: addressValue,
            parameterValue: parameterValue,
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

        emit ProposalCreated(proposalId, pType, proposerId, targetId);
    }

    // ================================================================
    //                      VIEW FUNCTIONS
    // ================================================================

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
