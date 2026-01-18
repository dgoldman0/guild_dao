// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/// @notice Minimal interface into RankedMembershipDAO
interface IRankedMembershipDAO {
    enum Rank { G, F, E, D, C, B, A, S, SS, SSS }

    function memberIdByAuthority(address a) external view returns (uint32);

    function membersById(uint32 id)
        external
        view
        returns (
            bool exists,
            uint32 memberId,
            Rank rank,
            address authority,
            uint64 joinedAt
        );

    function votingPowerOfMemberAt(uint32 memberId, uint32 blockNumber) external view returns (uint224);
    function totalVotingPowerAt(uint32 blockNumber) external view returns (uint224);

    function proposalLimitOfRank(Rank r) external pure returns (uint8);
}

contract MembershipTreasury is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeCast for uint256;

    // ----------------------------
    // Params
    // ----------------------------

    uint64 public constant VOTING_PERIOD = 7 days;
    uint16 public constant QUORUM_BPS = 2000; // 20%
    uint64 public constant EXECUTION_DELAY = 24 hours; // timelock after passing

    IRankedMembershipDAO public immutable dao;

    // ----------------------------
    // Treasury Proposal System
    // ----------------------------

    enum ActionType { TransferETH, TransferERC20, Call }

    struct Action {
        ActionType actionType;

        address target;     // recipient for transfers; call target for Call
        address token;      // ERC20 token for TransferERC20
        uint256 value;      // ETH value for TransferETH/Call or token amount for TransferERC20
        bytes data;         // calldata for Call
    }

    struct Proposal {
        bool exists;
        uint64 id;

        uint32 proposerId;
        IRankedMembershipDAO.Rank proposerRank;

        uint32 snapshotBlock;
        uint64 startTime;
        uint64 endTime;

        uint224 yesVotes;
        uint224 noVotes;

        bool finalized;
        bool succeeded;

        uint64 executableAfter;
        bool executed;

        Action action;
    }

    uint64 public nextProposalId = 1;
    mapping(uint64 => Proposal) public proposals;
    mapping(uint64 => mapping(uint32 => bool)) public hasVoted;

    // proposer memberId => active proposals
    mapping(uint32 => uint16) public activeProposalsOf;

    // ----------------------------
    // Optional spend caps
    // ----------------------------

    bool public capsEnabled;

    // asset => daily cap (asset=address(0) for ETH)
    mapping(address => uint256) public dailyCap;

    // asset => dayIndex => spent amount
    mapping(address => mapping(uint64 => uint256)) public spentPerDay;

    // ----------------------------
    // Errors
    // ----------------------------

    error NotMember();
    error InvalidAddress();
    error ProposalNotFound();
    error ProposalNotActive();
    error ProposalEnded();
    error ProposalAlreadyFinalized();
    error AlreadyVoted();
    error TooManyActiveProposals();
    error QuorumNotMet();
    error NotReady();
    error ExecutionFailed();
    error CapExceeded();
    error ActionDisabled();

    // ----------------------------
    // Events
    // ----------------------------

    event DepositedETH(address indexed from, uint256 amount);
    event DepositedERC20(address indexed token, address indexed from, uint256 amount);

    event TreasuryProposalCreated(
        uint64 indexed proposalId,
        uint32 indexed proposerId,
        ActionType actionType,
        address indexed target,
        address token,
        uint256 value,
        uint64 startTime,
        uint64 endTime,
        uint32 snapshotBlock
    );
    event TreasuryVoteCast(uint64 indexed proposalId, uint32 indexed voterId, bool support, uint224 weight);
    event TreasuryProposalFinalized(uint64 indexed proposalId, bool succeeded, uint224 yesVotes, uint224 noVotes, uint64 executableAfter);
    event TreasuryProposalExecuted(uint64 indexed proposalId);

    event CapsEnabled(bool enabled);
    event DailyCapSet(address indexed asset, uint256 cap);

    // ----------------------------
    // Constructor
    // ----------------------------

    constructor(address daoAddress) Ownable2Step(msg.sender) {
        if (daoAddress == address(0)) revert InvalidAddress();
        dao = IRankedMembershipDAO(daoAddress);
    }

    // ----------------------------
    // Receive ETH
    // ----------------------------

    receive() external payable {
        emit DepositedETH(msg.sender, msg.value);
    }

    function depositERC20(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (token == address(0)) revert InvalidAddress();
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        emit DepositedERC20(token, msg.sender, amount);
    }

    // ----------------------------
    // Admin safety
    // ----------------------------

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setCapsEnabled(bool enabled) external onlyOwner {
        capsEnabled = enabled;
        emit CapsEnabled(enabled);
    }

    function setDailyCap(address asset, uint256 cap) external onlyOwner {
        // asset=0 => ETH cap
        dailyCap[asset] = cap;
        emit DailyCapSet(asset, cap);
    }

    // If you want to disable arbitrary Call actions permanently, flip this to false.
    bool public callActionsEnabled = true;
    function setCallActionsEnabled(bool enabled) external onlyOwner {
        callActionsEnabled = enabled;
    }

    // ----------------------------
    // Membership helpers
    // ----------------------------

    function _requireMember(address who) internal view returns (uint32 memberId, IRankedMembershipDAO.Rank rank) {
        memberId = dao.memberIdByAuthority(who);
        if (memberId == 0) revert NotMember();
        (bool exists,, IRankedMembershipDAO.Rank r, address authority,) = dao.membersById(memberId);
        if (!exists || authority != who) revert NotMember();
        rank = r;
    }

    function _proposalLimit(IRankedMembershipDAO.Rank r) internal pure returns (uint8) {
        // mirror DAO behavior via interface call (pure there)
        return IRankedMembershipDAO.proposalLimitOfRank(r);
    }

    function _enforceProposalLimit(uint32 proposerId, IRankedMembershipDAO.Rank rank) internal view {
        uint8 limit = _proposalLimit(rank);
        if (activeProposalsOf[proposerId] >= limit) revert TooManyActiveProposals();
    }

    // ----------------------------
    // Create proposals
    // ----------------------------

    function proposeTransferETH(address to, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        returns (uint64 proposalId)
    {
        if (to == address(0)) revert InvalidAddress();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        // require at least F (same as DAO’s proposal gate)
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();

        _enforceProposalLimit(proposerId, rank);

        Proposal memory p;
        proposalId = nextProposalId++;
        p.exists = true;
        p.id = proposalId;
        p.proposerId = proposerId;
        p.proposerRank = rank;
        p.snapshotBlock = block.number.toUint32();
        p.startTime = uint64(block.timestamp);
        p.endTime = p.startTime + VOTING_PERIOD;

        p.action = Action({
            actionType: ActionType.TransferETH,
            target: to,
            token: address(0),
            value: amount,
            data: ""
        });

        proposals[proposalId] = p;
        activeProposalsOf[proposerId] += 1;

        emit TreasuryProposalCreated(
            proposalId, proposerId, ActionType.TransferETH, to, address(0), amount,
            p.startTime, p.endTime, p.snapshotBlock
        );
    }

    function proposeTransferERC20(address token, address to, uint256 amount)
        external
        whenNotPaused
        nonReentrant
        returns (uint64 proposalId)
    {
        if (token == address(0) || to == address(0)) revert InvalidAddress();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();

        _enforceProposalLimit(proposerId, rank);

        Proposal memory p;
        proposalId = nextProposalId++;
        p.exists = true;
        p.id = proposalId;
        p.proposerId = proposerId;
        p.proposerRank = rank;
        p.snapshotBlock = block.number.toUint32();
        p.startTime = uint64(block.timestamp);
        p.endTime = p.startTime + VOTING_PERIOD;

        p.action = Action({
            actionType: ActionType.TransferERC20,
            target: to,
            token: token,
            value: amount,
            data: ""
        });

        proposals[proposalId] = p;
        activeProposalsOf[proposerId] += 1;

        emit TreasuryProposalCreated(
            proposalId, proposerId, ActionType.TransferERC20, to, token, amount,
            p.startTime, p.endTime, p.snapshotBlock
        );
    }

    function proposeCall(address target, uint256 value, bytes calldata data)
        external
        whenNotPaused
        nonReentrant
        returns (uint64 proposalId)
    {
        if (!callActionsEnabled) revert ActionDisabled();
        if (target == address(0)) revert InvalidAddress();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();

        _enforceProposalLimit(proposerId, rank);

        Proposal memory p;
        proposalId = nextProposalId++;
        p.exists = true;
        p.id = proposalId;
        p.proposerId = proposerId;
        p.proposerRank = rank;
        p.snapshotBlock = block.number.toUint32();
        p.startTime = uint64(block.timestamp);
        p.endTime = p.startTime + VOTING_PERIOD;

        p.action = Action({
            actionType: ActionType.Call,
            target: target,
            token: address(0),
            value: value,
            data: data
        });

        proposals[proposalId] = p;
        activeProposalsOf[proposerId] += 1;

        emit TreasuryProposalCreated(
            proposalId, proposerId, ActionType.Call, target, address(0), value,
            p.startTime, p.endTime, p.snapshotBlock
        );
    }

    // ----------------------------
    // Voting
    // ----------------------------

    function castVote(uint64 proposalId, bool support) external whenNotPaused nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.finalized) revert ProposalAlreadyFinalized();
        if (block.timestamp < p.startTime) revert ProposalNotActive();
        if (block.timestamp > p.endTime) revert ProposalEnded();

        (uint32 voterId,) = _requireMember(msg.sender);
        if (hasVoted[proposalId][voterId]) revert AlreadyVoted();
        hasVoted[proposalId][voterId] = true;

        uint224 weight = dao.votingPowerOfMemberAt(voterId, p.snapshotBlock);

        if (support) p.yesVotes += weight;
        else p.noVotes += weight;

        emit TreasuryVoteCast(proposalId, voterId, support, weight);
    }

    // ----------------------------
    // Finalize + Execute
    // ----------------------------

    function finalize(uint64 proposalId) external whenNotPaused nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.finalized) revert ProposalAlreadyFinalized();
        if (block.timestamp <= p.endTime) revert NotReady();

        p.finalized = true;

        // decrement proposer active proposals
        if (activeProposalsOf[p.proposerId] > 0) {
            activeProposalsOf[p.proposerId] -= 1;
        }

        uint224 totalAtSnap = dao.totalVotingPowerAt(p.snapshotBlock);
        uint224 votesCast = p.yesVotes + p.noVotes;

        uint256 required = (uint256(totalAtSnap) * QUORUM_BPS) / 10_000;
        if (votesCast < required) {
            p.succeeded = false;
            emit TreasuryProposalFinalized(proposalId, false, p.yesVotes, p.noVotes, 0);
            return;
        }

        if (p.yesVotes <= p.noVotes) {
            p.succeeded = false;
            emit TreasuryProposalFinalized(proposalId, false, p.yesVotes, p.noVotes, 0);
            return;
        }

        p.succeeded = true;
        p.executableAfter = uint64(block.timestamp + EXECUTION_DELAY);

        emit TreasuryProposalFinalized(proposalId, true, p.yesVotes, p.noVotes, p.executableAfter);
    }

    function execute(uint64 proposalId) external whenNotPaused nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (!p.finalized || !p.succeeded) revert NotReady();
        if (p.executed) revert NotReady();
        if (block.timestamp < p.executableAfter) revert NotReady();

        // spend cap enforcement (optional)
        _enforceCap(p.action);

        p.executed = true;

        if (p.action.actionType == ActionType.TransferETH) {
            (bool ok,) = p.action.target.call{value: p.action.value}("");
            if (!ok) revert ExecutionFailed();
        } else if (p.action.actionType == ActionType.TransferERC20) {
            IERC20(p.action.token).transfer(p.action.target, p.action.value);
        } else if (p.action.actionType == ActionType.Call) {
            if (!callActionsEnabled) revert ActionDisabled();
            (bool ok,) = p.action.target.call{value: p.action.value}(p.action.data);
            if (!ok) revert ExecutionFailed();
        } else {
            revert ExecutionFailed();
        }

        emit TreasuryProposalExecuted(proposalId);
    }

    function _enforceCap(Action memory a) internal {
        if (!capsEnabled) return;

        address asset = (a.actionType == ActionType.TransferERC20) ? a.token : address(0);
        uint256 cap = dailyCap[asset];
        if (cap == 0) return; // cap of 0 means "no cap"

        uint64 dayIndex = uint64(block.timestamp / 1 days);
        uint256 already = spentPerDay[asset][dayIndex];
        uint256 spend = a.value;

        // for Call, treat as ETH-spend cap only (value). If you want token caps on calls,
        // enforce with "Call disabled" or do whitelisted call targets.
        if (already + spend > cap) revert CapExceeded();

        spentPerDay[asset][dayIndex] = already + spend;
    }

    // ----------------------------
    // Views
    // ----------------------------

    function getProposal(uint64 proposalId) external view returns (Proposal memory) {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        return p;
    }

    function balanceETH() external view returns (uint256) {
        return address(this).balance;
    }

    function balanceERC20(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
