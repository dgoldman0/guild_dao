// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    OrderController — Timelocked hierarchical order system for the
    RankedMembershipDAO.

    Manages:
      - Promotion grants (target must accept after delay)
      - Demotion orders  (auto-execute after delay)
      - Authority orders  (auto-execute after delay)
      - Veto / block by higher-ranked members
      - Rescind by issuer
      - Block-by-governance (called by ProposalController)

    This contract calls setRank() and setAuthority() through the
    GuildController (the DAO's sole controller).
*/

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RankedMembershipDAO} from "./RankedMembershipDAO.sol";
import {GuildController} from "./GuildController.sol";

contract OrderController is ReentrancyGuard {

    // ================================================================
    //                        DAO REFERENCE
    // ================================================================

    RankedMembershipDAO public immutable dao;
    GuildController public immutable guildCtrl;

    /// @notice The ProposalController address — allowed to call blockOrderByGovernance().
    address public proposalController;

    // ================================================================
    //                          ERRORS
    // ================================================================

    error NotMember();
    error AlreadyMember();
    error InvalidAddress();
    error RankTooLow();
    error PendingActionExists();
    error NoPendingAction();
    error NotAuthorizedAuthority();
    error InvalidPromotion();
    error InvalidDemotion();
    error InvalidTarget();
    error VetoNotAllowed();
    error OrderNotReady();
    error OrderIsBlocked();
    error OrderWrongType();
    error TooManyActiveOrders();
    error NotProposalController();

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
    //                          EVENTS
    // ================================================================

    event OrderCreated(uint64 indexed orderId, OrderType orderType, uint32 indexed issuerId, uint32 indexed targetId, RankedMembershipDAO.Rank newRank, address newAuthority, uint64 executeAfter);
    event OrderBlocked(uint64 indexed orderId, uint32 indexed blockerId);
    event OrderBlockedByGovernance(uint64 indexed orderId, uint64 indexed proposalId);
    event OrderExecuted(uint64 indexed orderId);
    event OrderRescinded(uint64 indexed orderId, uint32 indexed issuerId);
    event ProposalControllerSet(address indexed proposalController);

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
    //                    ADMIN
    // ================================================================

    /// @notice Set the ProposalController address (authorized for blockOrderByGovernance).
    ///         Callable by the DAO owner (bootstrap) or the current proposalController.
    function setProposalController(address newProposalController) external {
        if (msg.sender != dao.owner() && msg.sender != dao.controller() && msg.sender != proposalController)
            revert NotProposalController();
        if (newProposalController == address(0)) revert InvalidAddress();
        proposalController = newProposalController;
        emit ProposalControllerSet(newProposalController);
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
    //               ORDER FUNCTIONS
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

        guildCtrl.setRank(targetId, o.newRank, callerId, false);

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
                guildCtrl.setRank(targetId, newRank, o.issuerId, false);
            }
        } else if (o.orderType == OrderType.AuthorityOrder) {
            if (dao.memberIdByAuthority(o.newAuthority) != 0) revert AlreadyMember();
            guildCtrl.setAuthority(targetId, o.newAuthority, o.issuerId, false);
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
    //          GOVERNANCE BRIDGE (called by ProposalController)
    // ================================================================

    /// @notice Block an order via governance vote.  Only callable by the ProposalController.
    function blockOrderByGovernance(uint64 orderId, uint64 proposalId) external {
        if (msg.sender != proposalController) revert NotProposalController();

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

        emit OrderBlockedByGovernance(orderId, proposalId);
    }

    // ================================================================
    //                      VIEW FUNCTIONS
    // ================================================================

    function getOrder(uint64 orderId) external view returns (PendingOrder memory) {
        return ordersById[orderId];
    }
}
