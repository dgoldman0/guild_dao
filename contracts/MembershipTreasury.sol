// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    MembershipTreasury  —  Holds ETH / ERC-20 / NFTs for the DAO.

    Architecture
    ────────────
    • Members create proposals via a single generic `propose(actionType, data)`.
    • Other members vote, anyone can finalize after the voting period.
    • Basic execution (transfers, calls, settings) runs locally.
    • Treasurer / NFT management actions are forwarded to the TreasurerModule.
    • The TreasurerModule calls back via `moduleTransfer*` / `moduleCall` to move
      funds.  Those entry-points are restricted by `onlyModule`.
*/

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IRankedMembershipDAO} from "./interfaces/IRankedMembershipDAO.sol";
import {ITreasurerModule} from "./interfaces/ITreasurerModule.sol";
import {ActionTypes} from "./libraries/ActionTypes.sol";

contract MembershipTreasury is ReentrancyGuard, Ownable, IERC721Receiver {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    // ═══════════════════════════════ Constants ════════════════════════════════

    uint64 public constant VOTING_DELAY = 1; // blocks after snapshot before voting opens

    // ═══════════════════════════════ Immutables ══════════════════════════════

    IRankedMembershipDAO public immutable dao;

    // ═══════════════════════════════ Module ═══════════════════════════════════

    address public treasurerModule;

    // ═══════════════════════════════ Proposals ════════════════════════════════

    struct Proposal {
        bool    exists;
        uint64  id;
        uint32  proposerId;
        uint8   proposerRank;   // stored as uint8 to keep struct tight
        uint32  snapshotBlock;
        uint64  startTime;
        uint64  endTime;
        uint224 yesVotes;
        uint224 noVotes;
        bool    finalized;
        bool    succeeded;
        uint64  executableAfter;
        bool    executed;
        uint8   actionType;
        bytes   data;           // abi-encoded payload; format depends on actionType
    }

    uint64 public nextProposalId = 1;
    mapping(uint64 => Proposal)                   internal _proposals;
    mapping(uint64 => mapping(uint32 => bool))    public   hasVoted;
    mapping(uint32 => uint16)                     public   activeProposalsOf;

    // ═══════════════════════════════ Settings ═════════════════════════════════

    bool public callActionsEnabled;
    bool public treasurerCallsEnabled;
    mapping(address => bool) public approvedCallTargets;
    bool public treasuryLocked;

    // ═══════════════════════════════ Spend Caps ══════════════════════════════

    bool public capsEnabled;
    mapping(address => uint256)                   public dailyCap;     // asset ⇒ cap (address(0)=ETH)
    mapping(address => mapping(uint64 => uint256)) public spentPerDay;

    // ═══════════════════════════════ Errors ═══════════════════════════════════

    error NotMember();
    error InvalidAddress();
    error ProposalNotFound();
    error ProposalNotActive();
    error ProposalEnded();
    error ProposalAlreadyFinalized();
    error AlreadyVoted();
    error TooManyActiveProposals();
    error NotReady();
    error ExecutionFailed();
    error CapExceeded();
    error ActionDisabled();
    error ZeroAmount();
    error TreasuryLocked();
    error VotingNotStarted();
    error CallTargetNotApproved();
    error NotModule();
    error InvalidActionType();
    error ModuleAlreadySet();

    // ═══════════════════════════════ Events ═══════════════════════════════════

    event DepositedETH(address indexed from, uint256 amount);
    event DepositedERC20(address indexed token, address indexed from, uint256 amount);
    event DepositedNFT(address indexed nftContract, address indexed from, uint256 tokenId);

    event ProposalCreated(
        uint64 indexed proposalId, uint32 indexed proposerId,
        uint8 actionType, uint64 startTime, uint64 endTime, uint32 snapshotBlock
    );
    event VoteCast(
        uint64 indexed proposalId, uint32 indexed voterId, bool support, uint224 weight
    );
    event ProposalFinalized(
        uint64 indexed proposalId, bool succeeded,
        uint224 yesVotes, uint224 noVotes, uint64 executableAfter
    );
    event ProposalExecuted(uint64 indexed proposalId);

    event CapsEnabled(bool enabled);
    event DailyCapSet(address indexed asset, uint256 cap);
    event CallActionsEnabledSet(bool enabled);
    event TreasurerCallsEnabledSet(bool enabled);
    event ApprovedCallTargetAdded(address indexed target);
    event ApprovedCallTargetRemoved(address indexed target);
    event TreasuryLockedSet(bool locked);
    event TreasurerModuleSet(address indexed module);

    // ═══════════════════════════════ Modifiers ════════════════════════════════

    modifier onlyModule() {
        if (msg.sender != treasurerModule) revert NotModule();
        _;
    }

    // ═══════════════════════════════ Constructor ══════════════════════════════

    constructor(address daoAddress) Ownable(msg.sender) {
        if (daoAddress == address(0)) revert InvalidAddress();
        dao = IRankedMembershipDAO(daoAddress);
    }

    /// @notice Wire the TreasurerModule.  Owner-only, one-shot.
    function setTreasurerModule(address moduleAddress) external onlyOwner {
        if (moduleAddress == address(0)) revert InvalidAddress();
        if (treasurerModule != address(0)) revert ModuleAlreadySet();
        treasurerModule = moduleAddress;
        emit TreasurerModuleSet(moduleAddress);
    }

    // ═══════════════════════════════ Deposits ═════════════════════════════════

    receive() external payable {
        emit DepositedETH(msg.sender, msg.value);
    }

    function depositERC20(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit DepositedERC20(token, msg.sender, amount);
    }

    function depositNFT(address nftContract, uint256 tokenId) external nonReentrant {
        if (nftContract == address(0)) revert InvalidAddress();
        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);
        emit DepositedNFT(nftContract, msg.sender, tokenId);
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external returns (bytes4)
    {
        emit DepositedNFT(msg.sender, from, tokenId);
        return this.onERC721Received.selector;
    }

    // ═══════════════════════════════ Admin ════════════════════════════════════

    function setCapsEnabled(bool enabled) external onlyOwner {
        capsEnabled = enabled;
        emit CapsEnabled(enabled);
    }

    function setDailyCap(address asset, uint256 cap) external onlyOwner {
        dailyCap[asset] = cap;
        emit DailyCapSet(asset, cap);
    }

    // ═══════════════════════════════ Module Transfers ═════════════════════════
    //  Called by TreasurerModule to move funds.  NO nonReentrant here because
    //  these may be called within an already-guarded execute() or the module's
    //  own nonReentrant spending functions.

    function moduleTransferETH(address to, uint256 amount) external onlyModule {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ExecutionFailed();
    }

    function moduleTransferERC20(address token, address to, uint256 amount) external onlyModule {
        IERC20(token).safeTransfer(to, amount);
    }

    function moduleTransferNFT(address nftContract, address to, uint256 tokenId) external onlyModule {
        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
    }

    function moduleCall(address target, uint256 value, bytes calldata data)
        external onlyModule returns (bytes memory result)
    {
        bool ok;
        (ok, result) = target.call{value: value}(data);
        if (!ok) revert ExecutionFailed();
    }

    // ═══════════════════════════════ Propose (generic) ════════════════════════
    //
    //  Data encoding per action type:
    //
    //  TRANSFER_ETH           → abi.encode(address to, uint256 amount)
    //  TRANSFER_ERC20         → abi.encode(address token, address to, uint256 amount)
    //  CALL                   → abi.encode(address target, uint256 value, bytes data)
    //  ADD_MEMBER_TREASURER   → abi.encode(uint32 memberId, uint256 baseLim,
    //                            uint256 limPerRank, uint64 period, uint8 minRank)
    //  UPDATE_MEMBER_TREASURER→ (same encoding as ADD)
    //  REMOVE_MEMBER_TREASURER→ abi.encode(uint32 memberId)
    //  ADD_ADDRESS_TREASURER  → abi.encode(address treasurer, uint256 baseLim, uint64 period)
    //  UPDATE_ADDRESS_TREASURER→ (same encoding as ADD)
    //  REMOVE_ADDRESS_TREASURER→ abi.encode(address treasurer)
    //  SET_MEMBER_TOKEN_CONFIG→ abi.encode(uint32 memberId, address token,
    //                            uint256 baseLim, uint256 limPerRank)
    //  SET_ADDRESS_TOKEN_CONFIG→ abi.encode(address treasurer, address token, uint256 limit)
    //  TRANSFER_NFT           → abi.encode(address nftContract, address to, uint256 tokenId)
    //  GRANT_MEMBER_NFT_ACCESS→ abi.encode(uint32 memberId, address nftContract,
    //                            uint64 txPerPeriod, uint64 period, uint8 minRank)
    //  REVOKE_MEMBER_NFT_ACCESS→ abi.encode(uint32 memberId, address nftContract)
    //  GRANT_ADDRESS_NFT_ACCESS→ abi.encode(address treasurer, address nftContract,
    //                             uint64 txPerPeriod, uint64 period)
    //  REVOKE_ADDRESS_NFT_ACCESS→ abi.encode(address treasurer, address nftContract)
    //  SET_CALL_ACTIONS_ENABLED → abi.encode(bool enabled)
    //  SET_TREASURER_CALLS_ENABLED → abi.encode(bool enabled)
    //  ADD_APPROVED_CALL_TARGET   → abi.encode(address target)
    //  REMOVE_APPROVED_CALL_TARGET→ abi.encode(address target)
    //  SET_TREASURY_LOCKED        → abi.encode(bool locked)

    function propose(uint8 actionType, bytes calldata data)
        external nonReentrant returns (uint64 proposalId)
    {
        if (actionType > ActionTypes.MAX_ACTION_TYPE) revert InvalidActionType();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        proposalId = nextProposalId++;
        Proposal storage p = _proposals[proposalId];
        p.exists        = true;
        p.id            = proposalId;
        p.proposerId    = proposerId;
        p.proposerRank  = uint8(rank);
        p.snapshotBlock = block.number.toUint32();
        p.startTime     = uint64(block.timestamp);
        p.endTime       = p.startTime + dao.votingPeriod();
        p.actionType    = actionType;
        p.data          = data;

        activeProposalsOf[proposerId] += 1;

        emit ProposalCreated(
            proposalId, proposerId, actionType,
            p.startTime, p.endTime, p.snapshotBlock
        );
    }

    // ═══════════════════════════════ Vote ═════════════════════════════════════

    function castVote(uint64 proposalId, bool support) external nonReentrant {
        Proposal storage p = _proposals[proposalId];
        if (!p.exists)   revert ProposalNotFound();
        if (p.finalized) revert ProposalAlreadyFinalized();
        if (block.number <= p.snapshotBlock + VOTING_DELAY) revert VotingNotStarted();
        if (block.timestamp < p.startTime)  revert ProposalNotActive();
        if (block.timestamp > p.endTime)    revert ProposalEnded();

        (uint32 voterId,) = _requireMember(msg.sender);
        if (hasVoted[proposalId][voterId]) revert AlreadyVoted();
        hasVoted[proposalId][voterId] = true;

        uint224 weight = dao.votingPowerOfMemberAt(voterId, p.snapshotBlock);
        if (support) p.yesVotes += weight;
        else         p.noVotes  += weight;

        emit VoteCast(proposalId, voterId, support, weight);
    }

    // ═══════════════════════════════ Finalize ═════════════════════════════════

    function finalize(uint64 proposalId) external nonReentrant {
        Proposal storage p = _proposals[proposalId];
        if (!p.exists)   revert ProposalNotFound();
        if (p.finalized) revert ProposalAlreadyFinalized();
        if (block.timestamp <= p.endTime) revert NotReady();

        p.finalized = true;
        if (activeProposalsOf[p.proposerId] > 0) activeProposalsOf[p.proposerId] -= 1;

        uint224 totalAtSnap = dao.totalVotingPowerAt(p.snapshotBlock);
        uint224 votesCast   = p.yesVotes + p.noVotes;

        // Zero votes → fail
        if (votesCast == 0) {
            emit ProposalFinalized(proposalId, false, 0, 0, 0);
            return;
        }

        uint256 required = (uint256(totalAtSnap) * dao.quorumBps()) / 10_000;
        if (votesCast < required || p.yesVotes <= p.noVotes) {
            emit ProposalFinalized(proposalId, false, p.yesVotes, p.noVotes, 0);
            return;
        }

        p.succeeded = true;
        p.executableAfter = uint64(block.timestamp + dao.executionDelay());
        emit ProposalFinalized(proposalId, true, p.yesVotes, p.noVotes, p.executableAfter);
    }

    // ═══════════════════════════════ Execute ══════════════════════════════════

    function execute(uint64 proposalId) external nonReentrant {
        Proposal storage p = _proposals[proposalId];
        if (!p.exists)                      revert ProposalNotFound();
        if (!p.finalized || !p.succeeded)   revert NotReady();
        if (p.executed)                     revert NotReady();
        if (block.timestamp < p.executableAfter) revert NotReady();

        p.executed = true;
        uint8 at = p.actionType;

        // ─── Basic transfers ───
        if (at == ActionTypes.TRANSFER_ETH) {
            if (treasuryLocked) revert TreasuryLocked();
            (address to, uint256 amount) = abi.decode(p.data, (address, uint256));
            _enforceCap(address(0), amount);
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert ExecutionFailed();

        } else if (at == ActionTypes.TRANSFER_ERC20) {
            if (treasuryLocked) revert TreasuryLocked();
            (address token, address to, uint256 amount) =
                abi.decode(p.data, (address, address, uint256));
            _enforceCap(token, amount);
            IERC20(token).safeTransfer(to, amount);

        } else if (at == ActionTypes.CALL) {
            if (treasuryLocked)       revert TreasuryLocked();
            if (!callActionsEnabled)  revert ActionDisabled();
            (address target, uint256 value, bytes memory callData) =
                abi.decode(p.data, (address, uint256, bytes));
            if (!approvedCallTargets[target]) revert CallTargetNotApproved();
            _enforceCap(address(0), value);
            (bool ok,) = target.call{value: value}(callData);
            if (!ok) revert ExecutionFailed();

        // ─── Treasurer / NFT (forward to module) ───
        } else if (ActionTypes.isModuleAction(at)) {
            ITreasurerModule(treasurerModule).executeTreasurerAction(at, p.data);

        // ─── Settings ───
        } else if (at == ActionTypes.SET_CALL_ACTIONS_ENABLED) {
            callActionsEnabled = abi.decode(p.data, (bool));
            emit CallActionsEnabledSet(callActionsEnabled);

        } else if (at == ActionTypes.SET_TREASURER_CALLS_ENABLED) {
            treasurerCallsEnabled = abi.decode(p.data, (bool));
            emit TreasurerCallsEnabledSet(treasurerCallsEnabled);

        } else if (at == ActionTypes.ADD_APPROVED_CALL_TARGET) {
            address target = abi.decode(p.data, (address));
            approvedCallTargets[target] = true;
            emit ApprovedCallTargetAdded(target);

        } else if (at == ActionTypes.REMOVE_APPROVED_CALL_TARGET) {
            address target = abi.decode(p.data, (address));
            approvedCallTargets[target] = false;
            emit ApprovedCallTargetRemoved(target);

        } else if (at == ActionTypes.SET_TREASURY_LOCKED) {
            treasuryLocked = abi.decode(p.data, (bool));
            emit TreasuryLockedSet(treasuryLocked);

        } else {
            revert InvalidActionType();
        }

        emit ProposalExecuted(proposalId);
    }

    // ═══════════════════════════════ Internal ═════════════════════════════════

    function _requireMember(address who)
        internal view returns (uint32 memberId, IRankedMembershipDAO.Rank rank)
    {
        memberId = dao.memberIdByAuthority(who);
        if (memberId == 0) revert NotMember();
        (bool exists,, IRankedMembershipDAO.Rank r, address authority,) =
            dao.membersById(memberId);
        if (!exists || authority != who) revert NotMember();
        rank = r;
    }

    function _enforceProposalLimit(uint32 proposerId, IRankedMembershipDAO.Rank rank) internal view {
        if (activeProposalsOf[proposerId] >= dao.proposalLimitOfRank(rank))
            revert TooManyActiveProposals();
    }

    function _enforceCap(address asset, uint256 amount) internal {
        if (!capsEnabled) return;
        uint256 cap = dailyCap[asset];
        if (cap == 0) return;
        uint64 day = uint64(block.timestamp / 1 days);
        uint256 already = spentPerDay[asset][day];
        if (already + amount > cap) revert CapExceeded();
        spentPerDay[asset][day] = already + amount;
    }

    // ═══════════════════════════════ Views ════════════════════════════════════

    function getProposal(uint64 proposalId) external view returns (
        uint64 id, uint32 proposerId, uint8 proposerRank,
        uint32 snapshotBlock, uint64 startTime, uint64 endTime,
        uint224 yesVotes, uint224 noVotes,
        bool finalized, bool succeeded,
        uint64 executableAfter, bool executed, uint8 actionType
    ) {
        Proposal storage p = _proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        return (
            p.id, p.proposerId, p.proposerRank,
            p.snapshotBlock, p.startTime, p.endTime,
            p.yesVotes, p.noVotes,
            p.finalized, p.succeeded,
            p.executableAfter, p.executed, p.actionType
        );
    }

    function getProposalData(uint64 proposalId) external view returns (bytes memory) {
        if (!_proposals[proposalId].exists) revert ProposalNotFound();
        return _proposals[proposalId].data;
    }

    function balanceETH() external view returns (uint256) {
        return address(this).balance;
    }

    function balanceERC20(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function ownsNFT(address nftContract, uint256 tokenId) external view returns (bool) {
        try IERC721(nftContract).ownerOf(tokenId) returns (address nftOwner) {
            return nftOwner == address(this);
        } catch {
            return false;
        }
    }
}
