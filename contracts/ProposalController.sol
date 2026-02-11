// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    ProposalController — Democratic governance proposal system for the
    RankedMembershipDAO.

    Manages:
      - Proposal creation (rank, authority, parameter, ERC20 transfer, bootstrap fee reset)
      - Snapshot-based weighted voting
      - Quorum + majority finalization
      - Execution of passed proposals (calls DAO setters or OrderController bridge)
      - BlockOrder proposals (delegates to OrderController.blockOrderByGovernance)

    This contract is set as the `controller` on the DAO, giving it authority
    to call setRank(), setAuthority(), governance parameter setters,
    transferERC20(), and resetBootstrapFee().
*/

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {RankedMembershipDAO} from "./RankedMembershipDAO.sol";
import {OrderController} from "./OrderController.sol";

contract ProposalController is ReentrancyGuard {
    using SafeCast for uint256;

    // ================================================================
    //                        REFERENCES
    // ================================================================

    RankedMembershipDAO public immutable dao;
    OrderController public immutable orderCtrl;

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
    error OrderNotReady();
    error OrderIsBlocked();
    error InvalidParameterValue();
    error ParameterOutOfBounds();

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
        address addressValue;       // newAuthority
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

    event ProposalCreated(uint64 indexed proposalId, ProposalType proposalType, uint32 indexed proposerId, uint32 indexed targetId);
    event VoteCast(uint64 indexed proposalId, uint32 indexed voterId, bool support, uint224 weight);
    event ProposalFinalized(uint64 indexed proposalId, bool succeeded, uint224 yesVotes, uint224 noVotes);

    // ================================================================
    //                        CONSTRUCTOR
    // ================================================================

    constructor(address daoAddress, address orderControllerAddress) {
        if (daoAddress == address(0)) revert InvalidAddress();
        if (orderControllerAddress == address(0)) revert InvalidAddress();
        dao = RankedMembershipDAO(payable(daoAddress));
        orderCtrl = OrderController(orderControllerAddress);
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

    function _requireNoPendingOnTarget(uint32 targetId) internal view {
        if (orderCtrl.pendingOrderOfTarget(targetId) != 0) revert PendingActionExists();
    }

    // ================================================================
    //               PROPOSAL CREATION
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

        // Validate order exists and is blockable (read from OrderController)
        OrderController.PendingOrder memory o = orderCtrl.getOrder(orderId);
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
    //              VOTING
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
    //         FINALIZATION & EXECUTION
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
            // Delegate to OrderController
            orderCtrl.blockOrderByGovernance(p.orderIdToBlock, p.proposalId);
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
        _requireNoPendingOnTarget(targetId);

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

    function getProposal(uint64 proposalId) external view returns (Proposal memory) {
        return proposalsById[proposalId];
    }
}
