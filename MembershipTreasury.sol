// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
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

    function votingPowerOfRank(Rank r) external pure returns (uint224);

    // Governance parameters (configurable via DAO governance)
    function votingPeriod() external view returns (uint64);
    function quorumBps() external view returns (uint16);
    function executionDelay() external view returns (uint64);
}

contract MembershipTreasury is Ownable2Step, ReentrancyGuard {
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    // ----------------------------
    // Params (now read from DAO governance)
    // ----------------------------
    
    /// @notice Maximum spending limit per period to prevent excessive grants (M-04)
    uint256 public constant MAX_SPENDING_LIMIT = 10_000 ether;

    IRankedMembershipDAO public immutable dao;

    // ----------------------------
    // Treasury Proposal System
    // ----------------------------

    enum ActionType {
        TransferETH,
        TransferERC20,
        Call,
        // Treasurer management actions
        AddMemberTreasurer,
        UpdateMemberTreasurer,
        RemoveMemberTreasurer,
        AddAddressTreasurer,
        UpdateAddressTreasurer,
        RemoveAddressTreasurer,
        SetMemberTreasurerTokenConfig,
        SetAddressTreasurerTokenConfig,
        // NFT actions
        TransferNFT,
        // NFT Treasurer access actions
        GrantMemberNFTAccess,
        RevokeMemberNFTAccess,
        GrantAddressNFTAccess,
        RevokeAddressNFTAccess,
        // Settings actions (governance-controlled)
        SetCallActionsEnabled,
        SetTreasurerCallsEnabled,
        AddApprovedCallTarget,
        RemoveApprovedCallTarget,
        // Global treasury lock (halts all outbound activity except voting)
        SetTreasuryLocked
    }

    struct Action {
        ActionType actionType;

        address target;     // recipient for transfers; call target for Call; treasurer address for AddressTreasurer actions
        address token;      // ERC20 token for TransferERC20 or token config
        uint256 value;      // ETH value for TransferETH/Call or token amount for TransferERC20
        bytes data;         // calldata for Call or encoded treasurer config
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
    // Treasurer System
    // ----------------------------

    /// @notice Treasurer type: Member-based uses DAO rank, Address-based has direct authority
    enum TreasurerType { None, MemberBased, AddressBased }

    /// @notice Spending limit configuration for a treasurer
    struct TreasurerConfig {
        bool active;
        TreasurerType treasurerType;
        // For MemberBased: minimum rank required, spending limit per rank level
        // For AddressBased: direct spending limit
        uint256 baseSpendingLimit;        // base spending limit (ETH, in wei)
        uint256 spendingLimitPerRankPower; // additional limit multiplied by voting power (for MemberBased)
        uint64 periodDuration;            // spending limit reset period (e.g., 1 day, 1 week)
        IRankedMembershipDAO.Rank minRank; // minimum rank required (for MemberBased)
    }

    /// @notice Spending tracking for a treasurer
    struct TreasurerSpending {
        uint256 spentInPeriod;            // amount spent in current period (ETH)
        uint64 periodStart;               // when current period started
    }

    /// @notice Token-specific spending limits for treasurers
    struct TokenSpendingConfig {
        bool hasLimit;                    // whether this token has a specific limit
        uint256 baseLimit;                // base limit for this token
        uint256 limitPerRankPower;        // additional limit per rank power (for MemberBased)
    }

    /// @notice Encoded treasurer action data for proposals
    struct MemberTreasurerParams {
        uint32 memberId;
        uint256 baseSpendingLimit;
        uint256 spendingLimitPerRankPower;
        uint64 periodDuration;
        IRankedMembershipDAO.Rank minRank;
    }

    struct AddressTreasurerParams {
        address treasurer;
        uint256 baseSpendingLimit;
        uint64 periodDuration;
    }

    struct MemberTokenConfigParams {
        uint32 memberId;
        address token;
        uint256 baseLimit;
        uint256 limitPerRankPower;
    }

    struct AddressTokenConfigParams {
        address treasurer;
        address token;
        uint256 limit;
    }

    // ----------------------------
    // NFT Treasurer System
    // ----------------------------

    /// @notice NFT transfer proposal params
    struct NFTTransferParams {
        address nftContract;
        address to;
        uint256 tokenId;
    }

    /// @notice NFT access config for a treasurer (per collection)
    struct NFTAccessConfig {
        bool hasAccess;                   // whether treasurer can transfer NFTs from this collection
        uint64 transfersPerPeriod;        // max transfers allowed per period (0 = unlimited)
        uint64 periodDuration;            // period duration in seconds
        IRankedMembershipDAO.Rank minRank; // minimum rank required (for member-based)
    }

    /// @notice NFT access tracking
    struct NFTAccessTracking {
        uint64 transfersInPeriod;         // transfers made in current period
        uint64 periodStart;               // when current period started
    }

    /// @notice Params for granting member NFT access
    struct MemberNFTAccessParams {
        uint32 memberId;
        address nftContract;
        uint64 transfersPerPeriod;
        uint64 periodDuration;
        IRankedMembershipDAO.Rank minRank;
    }

    /// @notice Params for granting address NFT access
    struct AddressNFTAccessParams {
        address treasurer;
        address nftContract;
        uint64 transfersPerPeriod;
        uint64 periodDuration;
    }

    /// @notice Params for revoking NFT access
    struct RevokeNFTAccessParams {
        uint32 memberId;      // for member-based (0 if address-based)
        address treasurer;    // for address-based (address(0) if member-based)
        address nftContract;
    }

    // Member-based NFT access: memberId => nftContract => config
    mapping(uint32 => mapping(address => NFTAccessConfig)) public memberNFTAccess;
    // Member-based NFT tracking: memberId => nftContract => tracking
    mapping(uint32 => mapping(address => NFTAccessTracking)) public memberNFTTracking;

    // Address-based NFT access: address => nftContract => config
    mapping(address => mapping(address => NFTAccessConfig)) public addressNFTAccess;
    // Address-based NFT tracking: address => nftContract => tracking
    mapping(address => mapping(address => NFTAccessTracking)) public addressNFTTracking;

    // Member-based treasurers: memberId => config
    mapping(uint32 => TreasurerConfig) public memberTreasurers;
    mapping(uint32 => TreasurerSpending) public memberTreasurerSpending;
    // memberId => token => spent in period
    mapping(uint32 => mapping(address => uint256)) public memberTreasurerTokenSpent;
    // memberId => token => config
    mapping(uint32 => mapping(address => TokenSpendingConfig)) public memberTreasurerTokenConfigs;

    // Address-based treasurers: address => config
    mapping(address => TreasurerConfig) public addressTreasurers;
    mapping(address => TreasurerSpending) public addressTreasurerSpending;
    // address => token => spent in period
    mapping(address => mapping(address => uint256)) public addressTreasurerTokenSpent;
    // address => token => config
    mapping(address => mapping(address => TokenSpendingConfig)) public addressTreasurerTokenConfigs;

    // ----------------------------
    // Optional spend caps
    // ----------------------------

    bool public capsEnabled;

    // asset => daily cap (asset=address(0) for ETH)
    mapping(address => uint256) public dailyCap;

    // asset => dayIndex => spent amount
    mapping(address => mapping(uint64 => uint256)) public spentPerDay;

    // ----------------------------
    // Call Settings (governance-controlled)
    // ----------------------------

    // If true, arbitrary Call proposals can be executed (dangerous - requires vote)
    bool public callActionsEnabled = false;

    // If true, treasurers can execute calls (requires approvedCallTargets whitelist)
    bool public treasurerCallsEnabled = false;

    // Whitelist of approved contract targets for treasurer calls AND governance Call proposals
    mapping(address => bool) public approvedCallTargets;

    // Global treasury lock - when true, all outbound activity (transfers, calls) is blocked
    // Only voting and proposal creation remain active to allow unlocking via governance
    bool public treasuryLocked = false;

    // Voting delay after proposal creation (prevents flash governance attacks)
    uint64 public constant VOTING_DELAY = 1;

    // Maximum spending limit per rank power multiplier to prevent excessive grants
    uint256 public constant MAX_SPENDING_LIMIT_PER_RANK = 1_000 ether;

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
    error NotTreasurer();
    error TreasurerSpendingLimitExceeded();
    error TreasurerRankTooLow();
    error TreasurerNotActive();
    error TreasurerAlreadyExists();
    error InvalidTreasurerType();
    error InvalidPeriodDuration();
    error NoNFTAccess();
    error NFTTransferLimitExceeded();
    error NFTAccessAlreadyGranted();
    error NFTAccessNotGranted();
    error CallTargetNotApproved();
    error TreasurerCallsDisabled();
    error CallTargetAlreadyApproved();
    error CallTargetNotInWhitelist();
    error ZeroAmount();
    error NFTNotOwned();
    error SpendingLimitTooHigh();
    error TreasuryLocked();
    error VotingNotStarted();
    error InsufficientVotes();

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

    // Treasurer events
    event MemberTreasurerAdded(
        uint32 indexed memberId,
        uint256 baseSpendingLimit,
        uint256 spendingLimitPerRankPower,
        uint64 periodDuration,
        IRankedMembershipDAO.Rank minRank
    );
    event MemberTreasurerUpdated(
        uint32 indexed memberId,
        uint256 baseSpendingLimit,
        uint256 spendingLimitPerRankPower,
        uint64 periodDuration,
        IRankedMembershipDAO.Rank minRank
    );
    event MemberTreasurerRemoved(uint32 indexed memberId);
    event MemberTreasurerTokenConfigSet(uint32 indexed memberId, address indexed token, uint256 baseLimit, uint256 limitPerRankPower);

    event AddressTreasurerAdded(
        address indexed treasurer,
        uint256 baseSpendingLimit,
        uint64 periodDuration
    );
    event AddressTreasurerUpdated(
        address indexed treasurer,
        uint256 baseSpendingLimit,
        uint64 periodDuration
    );
    event AddressTreasurerRemoved(address indexed treasurer);
    event AddressTreasurerTokenConfigSet(address indexed treasurer, address indexed token, uint256 limit);

    event TreasurerSpent(
        address indexed spender,
        TreasurerType treasurerType,
        address indexed recipient,
        address indexed token,
        uint256 amount
    );

    // NFT events
    event DepositedNFT(address indexed nftContract, address indexed from, uint256 tokenId);
    event NFTTransferred(address indexed nftContract, address indexed to, uint256 tokenId);
    
    event MemberNFTAccessGranted(
        uint32 indexed memberId,
        address indexed nftContract,
        uint64 transfersPerPeriod,
        uint64 periodDuration,
        IRankedMembershipDAO.Rank minRank
    );
    event MemberNFTAccessRevoked(uint32 indexed memberId, address indexed nftContract);
    
    event AddressNFTAccessGranted(
        address indexed treasurer,
        address indexed nftContract,
        uint64 transfersPerPeriod,
        uint64 periodDuration
    );
    event AddressNFTAccessRevoked(address indexed treasurer, address indexed nftContract);
    
    event TreasurerNFTTransferred(
        address indexed spender,
        TreasurerType treasurerType,
        address indexed nftContract,
        address indexed to,
        uint256 tokenId
    );

    // Treasurer proposal events
    event TreasurerProposalCreated(
        uint64 indexed proposalId,
        uint32 indexed proposerId,
        ActionType actionType,
        bytes data,
        uint64 startTime,
        uint64 endTime,
        uint32 snapshotBlock
    );

    // Settings events
    event CallActionsEnabledSet(bool enabled);
    event TreasurerCallsEnabledSet(bool enabled);
    event ApprovedCallTargetAdded(address indexed target);
    event ApprovedCallTargetRemoved(address indexed target);
    event TreasuryLockedSet(bool locked);

    // Treasurer call event
    event TreasurerCallExecuted(
        address indexed spender,
        TreasurerType treasurerType,
        address indexed target,
        uint256 value,
        bytes data
    );

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

    function depositERC20(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit DepositedERC20(token, msg.sender, amount);
    }

    /// @notice Deposit an NFT to the treasury
    function depositNFT(address nftContract, uint256 tokenId) external nonReentrant {
        if (nftContract == address(0)) revert InvalidAddress();
        IERC721(nftContract).transferFrom(msg.sender, address(this), tokenId);
        emit DepositedNFT(nftContract, msg.sender, tokenId);
    }

    /// @notice Required to receive ERC721 tokens
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external returns (bytes4) {
        emit DepositedNFT(msg.sender, from, tokenId);
        return this.onERC721Received.selector;
    }

    // ----------------------------
    // Admin safety (caps only - treasury lock is governance-controlled)
    // ----------------------------

    function setCapsEnabled(bool enabled) external onlyOwner {
        capsEnabled = enabled;
        emit CapsEnabled(enabled);
    }

    function setDailyCap(address asset, uint256 cap) external onlyOwner {
        // asset=0 => ETH cap
        dailyCap[asset] = cap;
        emit DailyCapSet(asset, cap);
    }

    // ----------------------------
    // Treasurer Spending Functions
    // ----------------------------

    /// @notice Treasurer spends ETH directly (no proposal needed)
    function treasurerSpendETH(address to, uint256 amount) external nonReentrant {
        if (treasuryLocked) revert TreasuryLocked();
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();

        (TreasurerType tType, uint256 limit, uint32 memberId) = _getTreasurerInfo(msg.sender, address(0));
        if (tType == TreasurerType.None) revert NotTreasurer();

        _checkAndRecordTreasurerSpending(msg.sender, tType, memberId, address(0), amount, limit);

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ExecutionFailed();

        emit TreasurerSpent(msg.sender, tType, to, address(0), amount);
    }

    /// @notice Treasurer spends ERC20 directly (no proposal needed)
    function treasurerSpendERC20(address token, address to, uint256 amount) external nonReentrant {
        if (treasuryLocked) revert TreasuryLocked();
        if (token == address(0) || to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();

        (TreasurerType tType, uint256 limit, uint32 memberId) = _getTreasurerInfo(msg.sender, token);
        if (tType == TreasurerType.None) revert NotTreasurer();

        _checkAndRecordTreasurerSpending(msg.sender, tType, memberId, token, amount, limit);

        IERC20(token).safeTransfer(to, amount);

        emit TreasurerSpent(msg.sender, tType, to, token, amount);
    }

    /// @notice Treasurer transfers an NFT directly (if authorized for that collection)
    function treasurerTransferNFT(address nftContract, address to, uint256 tokenId) external nonReentrant {
        if (treasuryLocked) revert TreasuryLocked();
        if (nftContract == address(0) || to == address(0)) revert InvalidAddress();

        // Verify treasury owns the NFT before attempting transfer (M-07)
        try IERC721(nftContract).ownerOf(tokenId) returns (address owner) {
            if (owner != address(this)) revert NFTNotOwned();
        } catch {
            revert NFTNotOwned();
        }

        (TreasurerType tType, uint32 memberId, bool canTransfer) = _checkNFTAccess(msg.sender, nftContract);
        if (!canTransfer) revert NoNFTAccess();

        _checkAndRecordNFTTransfer(msg.sender, tType, memberId, nftContract);

        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);

        emit TreasurerNFTTransferred(msg.sender, tType, nftContract, to, tokenId);
    }

    /// @notice Treasurer executes a call on an approved contract (no proposal needed)
    /// @dev Requires treasurerCallsEnabled and target must be in approvedCallTargets whitelist
    /// @param target The contract to call (must be in approved whitelist)
    /// @param value ETH value to send with the call (counted against spending limit)
    /// @param data The calldata to execute
    function treasurerCall(address target, uint256 value, bytes calldata data) external nonReentrant {
        if (treasuryLocked) revert TreasuryLocked();
        if (target == address(0)) revert InvalidAddress();
        if (!treasurerCallsEnabled) revert TreasurerCallsDisabled();
        if (!approvedCallTargets[target]) revert CallTargetNotApproved();

        (TreasurerType tType, uint256 limit, uint32 memberId) = _getTreasurerInfo(msg.sender, address(0));
        if (tType == TreasurerType.None) revert NotTreasurer();

        // If sending ETH value, it counts against spending limit
        if (value > 0) {
            _checkAndRecordTreasurerSpending(msg.sender, tType, memberId, address(0), value, limit);
        }

        (bool ok,) = target.call{value: value}(data);
        if (!ok) revert ExecutionFailed();

        emit TreasurerCallExecuted(msg.sender, tType, target, value, data);
    }

    /// @notice Check if a treasurer has NFT access for a collection
    function _checkNFTAccess(address spender, address nftContract)
        internal
        view
        returns (TreasurerType tType, uint32 memberId, bool canTransfer)
    {
        // First check member-based access
        memberId = dao.memberIdByAuthority(spender);
        if (memberId != 0) {
            NFTAccessConfig storage config = memberNFTAccess[memberId][nftContract];
            if (config.hasAccess) {
                // Verify member still exists and has required rank
                (bool exists,, IRankedMembershipDAO.Rank rank,,) = dao.membersById(memberId);
                // Use explicit rank index comparison for clarity (M-03)
                if (exists && _rankIndex(rank) >= _rankIndex(config.minRank)) {
                    return (TreasurerType.MemberBased, memberId, true);
                }
            }
        }

        // Check address-based access
        NFTAccessConfig storage addrConfig = addressNFTAccess[spender][nftContract];
        if (addrConfig.hasAccess) {
            return (TreasurerType.AddressBased, 0, true);
        }

        return (TreasurerType.None, 0, false);
    }

    /// @notice Check and record NFT transfer against limits
    function _checkAndRecordNFTTransfer(
        address spender,
        TreasurerType tType,
        uint32 memberId,
        address nftContract
    ) internal {
        uint64 currentTime = uint64(block.timestamp);

        if (tType == TreasurerType.MemberBased) {
            NFTAccessConfig storage config = memberNFTAccess[memberId][nftContract];
            NFTAccessTracking storage tracking = memberNFTTracking[memberId][nftContract];

            // Reset period if expired
            if (config.periodDuration > 0 && currentTime >= tracking.periodStart + config.periodDuration) {
                tracking.periodStart = currentTime;
                tracking.transfersInPeriod = 0;
            }

            // Check limit (0 = unlimited)
            if (config.transfersPerPeriod > 0) {
                if (tracking.transfersInPeriod >= config.transfersPerPeriod) {
                    revert NFTTransferLimitExceeded();
                }
                tracking.transfersInPeriod++;
            }
        } else if (tType == TreasurerType.AddressBased) {
            NFTAccessConfig storage config = addressNFTAccess[spender][nftContract];
            NFTAccessTracking storage tracking = addressNFTTracking[spender][nftContract];

            // Reset period if expired
            if (config.periodDuration > 0 && currentTime >= tracking.periodStart + config.periodDuration) {
                tracking.periodStart = currentTime;
                tracking.transfersInPeriod = 0;
            }

            // Check limit (0 = unlimited)
            if (config.transfersPerPeriod > 0) {
                if (tracking.transfersInPeriod >= config.transfersPerPeriod) {
                    revert NFTTransferLimitExceeded();
                }
                tracking.transfersInPeriod++;
            }
        }
    }

    /// @notice Get treasurer info for an address
    /// @return tType The treasurer type
    /// @return limit The current spending limit
    /// @return memberId The member ID (0 for address-based)
    function _getTreasurerInfo(address spender, address token)
        internal
        view
        returns (TreasurerType tType, uint256 limit, uint32 memberId)
    {
        // First check if they are a member-based treasurer
        memberId = dao.memberIdByAuthority(spender);
        if (memberId != 0 && memberTreasurers[memberId].active) {
            TreasurerConfig storage config = memberTreasurers[memberId];

            // Verify member still exists and has required rank
            (bool exists,, IRankedMembershipDAO.Rank rank,,) = dao.membersById(memberId);
            if (!exists) return (TreasurerType.None, 0, 0);
            // Use explicit rank index comparison for clarity (M-03)
            if (_rankIndex(rank) < _rankIndex(config.minRank)) return (TreasurerType.None, 0, 0);

            // Calculate limit based on rank
            uint224 rankPower = dao.votingPowerOfRank(rank);
            
            if (token == address(0)) {
                limit = config.baseSpendingLimit + (config.spendingLimitPerRankPower * rankPower);
            } else {
                TokenSpendingConfig storage tokenConfig = memberTreasurerTokenConfigs[memberId][token];
                if (tokenConfig.hasLimit) {
                    limit = tokenConfig.baseLimit + (tokenConfig.limitPerRankPower * rankPower);
                } else {
                    // No token-specific limit, use ETH limit as fallback
                    limit = config.baseSpendingLimit + (config.spendingLimitPerRankPower * rankPower);
                }
            }

            return (TreasurerType.MemberBased, limit, memberId);
        }

        // Check if they are an address-based treasurer
        if (addressTreasurers[spender].active) {
            TreasurerConfig storage config = addressTreasurers[spender];
            
            if (token == address(0)) {
                limit = config.baseSpendingLimit;
            } else {
                TokenSpendingConfig storage tokenConfig = addressTreasurerTokenConfigs[spender][token];
                if (tokenConfig.hasLimit) {
                    limit = tokenConfig.baseLimit;
                } else {
                    // No token-specific limit, use ETH limit as fallback
                    limit = config.baseSpendingLimit;
                }
            }

            return (TreasurerType.AddressBased, limit, 0);
        }

        return (TreasurerType.None, 0, 0);
    }

    /// @notice Check and record treasurer spending
    function _checkAndRecordTreasurerSpending(
        address spender,
        TreasurerType tType,
        uint32 memberId,
        address token,
        uint256 amount,
        uint256 limit
    ) internal {
        uint64 currentTime = uint64(block.timestamp);
        uint64 periodDuration;
        uint256 spentInPeriod;
        uint64 periodStart;

        if (tType == TreasurerType.MemberBased) {
            TreasurerConfig storage config = memberTreasurers[memberId];
            periodDuration = config.periodDuration;
            TreasurerSpending storage spending = memberTreasurerSpending[memberId];
            periodStart = spending.periodStart;

            // Reset period if expired (H-02 FIX: properly handle period reset)
            bool periodExpired = currentTime >= periodStart + periodDuration;
            if (periodExpired) {
                spending.periodStart = currentTime;
                spending.spentInPeriod = 0;
                // Note: Token spending is tracked per-token but shares the same period
                // We only reset the current token here; other tokens will be lazily reset
                // when they're accessed after the period start has been updated
            }
            
            // Get spent amount for this asset
            if (token == address(0)) {
                spentInPeriod = periodExpired ? 0 : spending.spentInPeriod;
            } else {
                // For tokens, check if the last token spend was before the new period
                // This handles the case where ETH was spent (resetting periodStart)
                // but this token hasn't been spent yet in this period
                spentInPeriod = periodExpired ? 0 : memberTreasurerTokenSpent[memberId][token];
            }

            // Check limit
            if (spentInPeriod + amount > limit) revert TreasurerSpendingLimitExceeded();

            // Record spending
            if (token == address(0)) {
                spending.spentInPeriod = spentInPeriod + amount;
            } else {
                memberTreasurerTokenSpent[memberId][token] = spentInPeriod + amount;
            }
        } else if (tType == TreasurerType.AddressBased) {
            TreasurerConfig storage config = addressTreasurers[spender];
            periodDuration = config.periodDuration;
            TreasurerSpending storage spending = addressTreasurerSpending[spender];
            periodStart = spending.periodStart;

            // Reset period if expired
            if (currentTime >= periodStart + periodDuration) {
                spending.periodStart = currentTime;
                spending.spentInPeriod = 0;
                // Reset token spending too
                addressTreasurerTokenSpent[spender][token] = 0;
                spentInPeriod = 0;
            } else {
                if (token == address(0)) {
                    spentInPeriod = spending.spentInPeriod;
                } else {
                    spentInPeriod = addressTreasurerTokenSpent[spender][token];
                }
            }

            // Check limit
            if (spentInPeriod + amount > limit) revert TreasurerSpendingLimitExceeded();

            // Record spending
            if (token == address(0)) {
                spending.spentInPeriod = spentInPeriod + amount;
            } else {
                addressTreasurerTokenSpent[spender][token] = spentInPeriod + amount;
            }
        }
    }

    // ----------------------------
    // Treasurer View Functions
    // ----------------------------

    /// @notice Get member treasurer config
    function getMemberTreasurerConfig(uint32 memberId) external view returns (TreasurerConfig memory) {
        return memberTreasurers[memberId];
    }

    /// @notice Get address treasurer config
    function getAddressTreasurerConfig(address treasurer) external view returns (TreasurerConfig memory) {
        return addressTreasurers[treasurer];
    }

    /// @notice Get remaining spending limit for a treasurer (ETH)
    function getTreasurerRemainingLimit(address spender) external view returns (uint256 remaining) {
        (TreasurerType tType, uint256 limit, uint32 memberId) = _getTreasurerInfo(spender, address(0));
        if (tType == TreasurerType.None) return 0;

        uint64 currentTime = uint64(block.timestamp);
        uint256 spentInPeriod;

        if (tType == TreasurerType.MemberBased) {
            TreasurerConfig storage config = memberTreasurers[memberId];
            TreasurerSpending storage spending = memberTreasurerSpending[memberId];
            
            if (currentTime >= spending.periodStart + config.periodDuration) {
                return limit; // Period reset, full limit available
            }
            spentInPeriod = spending.spentInPeriod;
        } else {
            TreasurerConfig storage config = addressTreasurers[spender];
            TreasurerSpending storage spending = addressTreasurerSpending[spender];
            
            if (currentTime >= spending.periodStart + config.periodDuration) {
                return limit; // Period reset, full limit available
            }
            spentInPeriod = spending.spentInPeriod;
        }

        if (limit > spentInPeriod) {
            remaining = limit - spentInPeriod;
        } else {
            remaining = 0;
        }
    }

    /// @notice Get remaining spending limit for a treasurer for a specific token
    function getTreasurerRemainingTokenLimit(address spender, address token) external view returns (uint256 remaining) {
        (TreasurerType tType, uint256 limit, uint32 memberId) = _getTreasurerInfo(spender, token);
        if (tType == TreasurerType.None) return 0;

        uint64 currentTime = uint64(block.timestamp);
        uint256 spentInPeriod;

        if (tType == TreasurerType.MemberBased) {
            TreasurerConfig storage config = memberTreasurers[memberId];
            TreasurerSpending storage spending = memberTreasurerSpending[memberId];
            
            if (currentTime >= spending.periodStart + config.periodDuration) {
                return limit; // Period reset, full limit available
            }
            spentInPeriod = memberTreasurerTokenSpent[memberId][token];
        } else {
            TreasurerConfig storage config = addressTreasurers[spender];
            TreasurerSpending storage spending = addressTreasurerSpending[spender];
            
            if (currentTime >= spending.periodStart + config.periodDuration) {
                return limit; // Period reset, full limit available
            }
            spentInPeriod = addressTreasurerTokenSpent[spender][token];
        }

        if (limit > spentInPeriod) {
            remaining = limit - spentInPeriod;
        } else {
            remaining = 0;
        }
    }

    /// @notice Check if an address is a treasurer
    function isTreasurer(address spender) external view returns (bool, TreasurerType) {
        (TreasurerType tType,,) = _getTreasurerInfo(spender, address(0));
        return (tType != TreasurerType.None, tType);
    }

    // ----------------------------
    // Membership helpers
    // ----------------------------

    /// @notice Convert rank enum to numeric index for explicit comparisons (M-03)
    /// @dev Ranks are ordered G(0), F(1), E(2), D(3), C(4), B(5), A(6), S(7), SS(8), SSS(9)
    function _rankIndex(IRankedMembershipDAO.Rank r) internal pure returns (uint8) {
        return uint8(r);
    }

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
        nonReentrant
        returns (uint64 proposalId)
    {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();

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
        p.endTime = p.startTime + dao.votingPeriod();

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
        nonReentrant
        returns (uint64 proposalId)
    {
        if (token == address(0) || to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();

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
        p.endTime = p.startTime + dao.votingPeriod();

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
        p.endTime = p.startTime + dao.votingPeriod();

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
    // Treasurer Management Proposals
    // ----------------------------

    /// @notice Propose adding a member-based treasurer
    function proposeAddMemberTreasurer(
        uint32 memberId,
        uint256 baseSpendingLimit,
        uint256 spendingLimitPerRankPower,
        uint64 periodDuration,
        IRankedMembershipDAO.Rank minRank
    ) external nonReentrant returns (uint64 proposalId) {
        if (periodDuration == 0) revert InvalidPeriodDuration();
        
        // Verify member exists
        (bool memberExists,,,,) = dao.membersById(memberId);
        if (!memberExists) revert NotMember();
        if (memberTreasurers[memberId].active) revert TreasurerAlreadyExists();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(MemberTreasurerParams({
            memberId: memberId,
            baseSpendingLimit: baseSpendingLimit,
            spendingLimitPerRankPower: spendingLimitPerRankPower,
            periodDuration: periodDuration,
            minRank: minRank
        }));

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.AddMemberTreasurer,
            address(0),
            address(0),
            0,
            encodedData
        );
    }

    /// @notice Propose updating a member-based treasurer
    function proposeUpdateMemberTreasurer(
        uint32 memberId,
        uint256 baseSpendingLimit,
        uint256 spendingLimitPerRankPower,
        uint64 periodDuration,
        IRankedMembershipDAO.Rank minRank
    ) external nonReentrant returns (uint64 proposalId) {
        if (periodDuration == 0) revert InvalidPeriodDuration();
        if (!memberTreasurers[memberId].active) revert TreasurerNotActive();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(MemberTreasurerParams({
            memberId: memberId,
            baseSpendingLimit: baseSpendingLimit,
            spendingLimitPerRankPower: spendingLimitPerRankPower,
            periodDuration: periodDuration,
            minRank: minRank
        }));

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.UpdateMemberTreasurer,
            address(0),
            address(0),
            0,
            encodedData
        );
    }

    /// @notice Propose removing a member-based treasurer
    function proposeRemoveMemberTreasurer(uint32 memberId)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        if (!memberTreasurers[memberId].active) revert TreasurerNotActive();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(memberId);

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.RemoveMemberTreasurer,
            address(0),
            address(0),
            0,
            encodedData
        );
    }

    /// @notice Propose setting token config for a member treasurer
    function proposeSetMemberTreasurerTokenConfig(
        uint32 memberId,
        address token,
        uint256 baseLimit,
        uint256 limitPerRankPower
    ) external nonReentrant returns (uint64 proposalId) {
        if (!memberTreasurers[memberId].active) revert TreasurerNotActive();
        if (token == address(0)) revert InvalidAddress();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(MemberTokenConfigParams({
            memberId: memberId,
            token: token,
            baseLimit: baseLimit,
            limitPerRankPower: limitPerRankPower
        }));

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.SetMemberTreasurerTokenConfig,
            address(0),
            token,
            0,
            encodedData
        );
    }

    /// @notice Propose adding an address-based treasurer
    function proposeAddAddressTreasurer(
        address treasurer,
        uint256 baseSpendingLimit,
        uint64 periodDuration
    ) external nonReentrant returns (uint64 proposalId) {
        if (treasurer == address(0)) revert InvalidAddress();
        if (periodDuration == 0) revert InvalidPeriodDuration();
        if (addressTreasurers[treasurer].active) revert TreasurerAlreadyExists();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(AddressTreasurerParams({
            treasurer: treasurer,
            baseSpendingLimit: baseSpendingLimit,
            periodDuration: periodDuration
        }));

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.AddAddressTreasurer,
            treasurer,
            address(0),
            0,
            encodedData
        );
    }

    /// @notice Propose updating an address-based treasurer
    function proposeUpdateAddressTreasurer(
        address treasurer,
        uint256 baseSpendingLimit,
        uint64 periodDuration
    ) external nonReentrant returns (uint64 proposalId) {
        if (periodDuration == 0) revert InvalidPeriodDuration();
        if (!addressTreasurers[treasurer].active) revert TreasurerNotActive();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(AddressTreasurerParams({
            treasurer: treasurer,
            baseSpendingLimit: baseSpendingLimit,
            periodDuration: periodDuration
        }));

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.UpdateAddressTreasurer,
            treasurer,
            address(0),
            0,
            encodedData
        );
    }

    /// @notice Propose removing an address-based treasurer
    function proposeRemoveAddressTreasurer(address treasurer)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        if (!addressTreasurers[treasurer].active) revert TreasurerNotActive();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(treasurer);

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.RemoveAddressTreasurer,
            treasurer,
            address(0),
            0,
            encodedData
        );
    }

    /// @notice Propose setting token config for an address treasurer
    function proposeSetAddressTreasurerTokenConfig(
        address treasurer,
        address token,
        uint256 limit
    ) external nonReentrant returns (uint64 proposalId) {
        if (!addressTreasurers[treasurer].active) revert TreasurerNotActive();
        if (token == address(0)) revert InvalidAddress();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(AddressTokenConfigParams({
            treasurer: treasurer,
            token: token,
            limit: limit
        }));

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.SetAddressTreasurerTokenConfig,
            treasurer,
            token,
            0,
            encodedData
        );
    }

    // ----------------------------
    // NFT Proposal Functions
    // ----------------------------

    /// @notice Propose transferring an NFT from the treasury
    function proposeTransferNFT(address nftContract, address to, uint256 tokenId)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        if (nftContract == address(0) || to == address(0)) revert InvalidAddress();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(NFTTransferParams({
            nftContract: nftContract,
            to: to,
            tokenId: tokenId
        }));

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.TransferNFT,
            to,
            nftContract,
            tokenId,
            encodedData
        );

        emit TreasuryProposalCreated(
            proposalId, proposerId, ActionType.TransferNFT, to, nftContract, tokenId,
            uint64(block.timestamp), uint64(block.timestamp) + dao.votingPeriod(), block.number.toUint32()
        );
    }

    /// @notice Propose granting NFT access to a member-based treasurer
    function proposeGrantMemberNFTAccess(
        uint32 memberId,
        address nftContract,
        uint64 transfersPerPeriod,
        uint64 periodDuration,
        IRankedMembershipDAO.Rank minRank
    ) external nonReentrant returns (uint64 proposalId) {
        if (nftContract == address(0)) revert InvalidAddress();
        
        // Verify member exists
        (bool memberExists,,,,) = dao.membersById(memberId);
        if (!memberExists) revert NotMember();
        if (memberNFTAccess[memberId][nftContract].hasAccess) revert NFTAccessAlreadyGranted();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(MemberNFTAccessParams({
            memberId: memberId,
            nftContract: nftContract,
            transfersPerPeriod: transfersPerPeriod,
            periodDuration: periodDuration,
            minRank: minRank
        }));

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.GrantMemberNFTAccess,
            nftContract,
            address(0),
            0,
            encodedData
        );
    }

    /// @notice Propose revoking NFT access from a member-based treasurer
    function proposeRevokeMemberNFTAccess(uint32 memberId, address nftContract)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        if (nftContract == address(0)) revert InvalidAddress();
        if (!memberNFTAccess[memberId][nftContract].hasAccess) revert NFTAccessNotGranted();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(RevokeNFTAccessParams({
            memberId: memberId,
            treasurer: address(0),
            nftContract: nftContract
        }));

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.RevokeMemberNFTAccess,
            nftContract,
            address(0),
            0,
            encodedData
        );
    }

    /// @notice Propose granting NFT access to an address-based treasurer
    function proposeGrantAddressNFTAccess(
        address treasurer,
        address nftContract,
        uint64 transfersPerPeriod,
        uint64 periodDuration
    ) external nonReentrant returns (uint64 proposalId) {
        if (treasurer == address(0) || nftContract == address(0)) revert InvalidAddress();
        if (addressNFTAccess[treasurer][nftContract].hasAccess) revert NFTAccessAlreadyGranted();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(AddressNFTAccessParams({
            treasurer: treasurer,
            nftContract: nftContract,
            transfersPerPeriod: transfersPerPeriod,
            periodDuration: periodDuration
        }));

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.GrantAddressNFTAccess,
            treasurer,
            nftContract,
            0,
            encodedData
        );
    }

    /// @notice Propose revoking NFT access from an address-based treasurer
    function proposeRevokeAddressNFTAccess(address treasurer, address nftContract)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        if (nftContract == address(0)) revert InvalidAddress();
        if (!addressNFTAccess[treasurer][nftContract].hasAccess) revert NFTAccessNotGranted();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(RevokeNFTAccessParams({
            memberId: 0,
            treasurer: treasurer,
            nftContract: nftContract
        }));

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.RevokeAddressNFTAccess,
            treasurer,
            nftContract,
            0,
            encodedData
        );
    }

    // ----------------------------
    // Settings Proposal Functions (Governance-controlled)
    // ----------------------------

    /// @notice Propose enabling/disabling arbitrary Call actions for proposals
    function proposeSetCallActionsEnabled(bool enabled)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(enabled);

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.SetCallActionsEnabled,
            address(0),
            address(0),
            enabled ? 1 : 0,
            encodedData
        );
    }

    /// @notice Propose enabling/disabling treasurer Call functionality
    function proposeSetTreasurerCallsEnabled(bool enabled)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(enabled);

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.SetTreasurerCallsEnabled,
            address(0),
            address(0),
            enabled ? 1 : 0,
            encodedData
        );
    }

    /// @notice Propose adding a contract to the approved call targets whitelist
    function proposeAddApprovedCallTarget(address target)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        if (target == address(0)) revert InvalidAddress();
        if (approvedCallTargets[target]) revert CallTargetAlreadyApproved();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(target);

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.AddApprovedCallTarget,
            target,
            address(0),
            0,
            encodedData
        );
    }

    /// @notice Propose removing a contract from the approved call targets whitelist
    function proposeRemoveApprovedCallTarget(address target)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        if (target == address(0)) revert InvalidAddress();
        if (!approvedCallTargets[target]) revert CallTargetNotInWhitelist();

        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(target);

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.RemoveApprovedCallTarget,
            target,
            address(0),
            0,
            encodedData
        );
    }

    /// @notice Propose enabling/disabling the global treasury lock
    /// @dev When locked, all outbound activity (transfers and calls) is blocked.
    ///      Voting, finalization, and proposal creation remain active to allow unlocking.
    function proposeSetTreasuryLocked(bool locked)
        external
        nonReentrant
        returns (uint64 proposalId)
    {
        (uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
        if (rank < IRankedMembershipDAO.Rank.F) revert NotMember();
        _enforceProposalLimit(proposerId, rank);

        bytes memory encodedData = abi.encode(locked);

        proposalId = _createTreasurerProposal(
            proposerId,
            rank,
            ActionType.SetTreasuryLocked,
            address(0),
            address(0),
            locked ? 1 : 0,
            encodedData
        );
    }

    /// @notice Internal helper to create treasurer proposals
    function _createTreasurerProposal(
        uint32 proposerId,
        IRankedMembershipDAO.Rank rank,
        ActionType actionType,
        address target,
        address token,
        uint256 value,
        bytes memory data
    ) internal returns (uint64 proposalId) {
        Proposal memory p;
        proposalId = nextProposalId++;
        p.exists = true;
        p.id = proposalId;
        p.proposerId = proposerId;
        p.proposerRank = rank;
        p.snapshotBlock = block.number.toUint32();
        p.startTime = uint64(block.timestamp);
        p.endTime = p.startTime + dao.votingPeriod();

        p.action = Action({
            actionType: actionType,
            target: target,
            token: token,
            value: value,
            data: data
        });

        proposals[proposalId] = p;
        activeProposalsOf[proposerId] += 1;

        emit TreasurerProposalCreated(
            proposalId, proposerId, actionType, data,
            p.startTime, p.endTime, p.snapshotBlock
        );
    }

    // ----------------------------
    // Voting
    // ----------------------------

    function castVote(uint64 proposalId, bool support) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (p.finalized) revert ProposalAlreadyFinalized();
        // Voting delay: must wait at least VOTING_DELAY blocks after proposal creation (H-01)
        if (block.number <= p.snapshotBlock + VOTING_DELAY) revert VotingNotStarted();
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

    function finalize(uint64 proposalId) external nonReentrant {
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

        // Minimum quorum: at least 1 vote required to prevent zero-quorum edge case (M-01)
        if (votesCast == 0) {
            p.succeeded = false;
            emit TreasuryProposalFinalized(proposalId, false, p.yesVotes, p.noVotes, 0);
            return;
        }

        uint256 required = (uint256(totalAtSnap) * dao.quorumBps()) / 10_000;
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
        p.executableAfter = uint64(block.timestamp + dao.executionDelay());

        emit TreasuryProposalFinalized(proposalId, true, p.yesVotes, p.noVotes, p.executableAfter);
    }

    function execute(uint64 proposalId) external nonReentrant {
        Proposal storage p = proposals[proposalId];
        if (!p.exists) revert ProposalNotFound();
        if (!p.finalized || !p.succeeded) revert NotReady();
        if (p.executed) revert NotReady();
        if (block.timestamp < p.executableAfter) revert NotReady();

        // spend cap enforcement (optional) - only for transfer/call actions
        if (p.action.actionType == ActionType.TransferETH ||
            p.action.actionType == ActionType.TransferERC20 ||
            p.action.actionType == ActionType.Call) {
            _enforceCap(p.action);
        }

        p.executed = true;

        if (p.action.actionType == ActionType.TransferETH) {
            // Check global treasury lock for ETH transfers
            if (treasuryLocked) revert TreasuryLocked();
            (bool ok,) = p.action.target.call{value: p.action.value}("");
            if (!ok) revert ExecutionFailed();
        } else if (p.action.actionType == ActionType.TransferERC20) {
            // Check global treasury lock for ERC20 transfers
            if (treasuryLocked) revert TreasuryLocked();
            IERC20(p.action.token).safeTransfer(p.action.target, p.action.value);
        } else if (p.action.actionType == ActionType.Call) {
            // Check global treasury lock for Call actions
            if (treasuryLocked) revert TreasuryLocked();
            // Note: callActionsEnabled can change between proposal creation and execution.
            // This is intentional - governance can disable dangerous features for pending proposals.
            if (!callActionsEnabled) revert ActionDisabled();
            // C-01 FIX: Call targets must also be whitelisted for governance proposals
            if (!approvedCallTargets[p.action.target]) revert CallTargetNotApproved();
            (bool ok,) = p.action.target.call{value: p.action.value}(p.action.data);
            if (!ok) revert ExecutionFailed();
        } else if (p.action.actionType == ActionType.AddMemberTreasurer) {
            _executeAddMemberTreasurer(p.action.data);
        } else if (p.action.actionType == ActionType.UpdateMemberTreasurer) {
            _executeUpdateMemberTreasurer(p.action.data);
        } else if (p.action.actionType == ActionType.RemoveMemberTreasurer) {
            _executeRemoveMemberTreasurer(p.action.data);
        } else if (p.action.actionType == ActionType.SetMemberTreasurerTokenConfig) {
            _executeSetMemberTreasurerTokenConfig(p.action.data);
        } else if (p.action.actionType == ActionType.AddAddressTreasurer) {
            _executeAddAddressTreasurer(p.action.data);
        } else if (p.action.actionType == ActionType.UpdateAddressTreasurer) {
            _executeUpdateAddressTreasurer(p.action.data);
        } else if (p.action.actionType == ActionType.RemoveAddressTreasurer) {
            _executeRemoveAddressTreasurer(p.action.data);
        } else if (p.action.actionType == ActionType.SetAddressTreasurerTokenConfig) {
            _executeSetAddressTreasurerTokenConfig(p.action.data);
        } else if (p.action.actionType == ActionType.TransferNFT) {
            _executeTransferNFT(p.action.data);
        } else if (p.action.actionType == ActionType.GrantMemberNFTAccess) {
            _executeGrantMemberNFTAccess(p.action.data);
        } else if (p.action.actionType == ActionType.RevokeMemberNFTAccess) {
            _executeRevokeMemberNFTAccess(p.action.data);
        } else if (p.action.actionType == ActionType.GrantAddressNFTAccess) {
            _executeGrantAddressNFTAccess(p.action.data);
        } else if (p.action.actionType == ActionType.RevokeAddressNFTAccess) {
            _executeRevokeAddressNFTAccess(p.action.data);
        } else if (p.action.actionType == ActionType.SetCallActionsEnabled) {
            _executeSetCallActionsEnabled(p.action.data);
        } else if (p.action.actionType == ActionType.SetTreasurerCallsEnabled) {
            _executeSetTreasurerCallsEnabled(p.action.data);
        } else if (p.action.actionType == ActionType.AddApprovedCallTarget) {
            _executeAddApprovedCallTarget(p.action.data);
        } else if (p.action.actionType == ActionType.RemoveApprovedCallTarget) {
            _executeRemoveApprovedCallTarget(p.action.data);
        } else if (p.action.actionType == ActionType.SetTreasuryLocked) {
            _executeSetTreasuryLocked(p.action.data);
        } else {
            revert ExecutionFailed();
        }

        emit TreasuryProposalExecuted(proposalId);
    }

    // ----------------------------
    // Treasurer Execution Helpers
    // ----------------------------

    function _executeAddMemberTreasurer(bytes memory data) internal {
        MemberTreasurerParams memory params = abi.decode(data, (MemberTreasurerParams));
        
        // Re-validate at execution time
        (bool exists,,,,) = dao.membersById(params.memberId);
        if (!exists) revert NotMember();
        if (memberTreasurers[params.memberId].active) revert TreasurerAlreadyExists();
        
        // Validate spending limits are within bounds (M-04)
        if (params.baseSpendingLimit > MAX_SPENDING_LIMIT) revert SpendingLimitTooHigh();
        if (params.spendingLimitPerRankPower > MAX_SPENDING_LIMIT_PER_RANK) revert SpendingLimitTooHigh();

        memberTreasurers[params.memberId] = TreasurerConfig({
            active: true,
            treasurerType: TreasurerType.MemberBased,
            baseSpendingLimit: params.baseSpendingLimit,
            spendingLimitPerRankPower: params.spendingLimitPerRankPower,
            periodDuration: params.periodDuration,
            minRank: params.minRank
        });

        emit MemberTreasurerAdded(
            params.memberId,
            params.baseSpendingLimit,
            params.spendingLimitPerRankPower,
            params.periodDuration,
            params.minRank
        );
    }

    function _executeUpdateMemberTreasurer(bytes memory data) internal {
        MemberTreasurerParams memory params = abi.decode(data, (MemberTreasurerParams));
        
        if (!memberTreasurers[params.memberId].active) revert TreasurerNotActive();
        
        // Validate spending limits are within bounds (M-04)
        if (params.baseSpendingLimit > MAX_SPENDING_LIMIT) revert SpendingLimitTooHigh();
        if (params.spendingLimitPerRankPower > MAX_SPENDING_LIMIT_PER_RANK) revert SpendingLimitTooHigh();

        TreasurerConfig storage config = memberTreasurers[params.memberId];
        config.baseSpendingLimit = params.baseSpendingLimit;
        config.spendingLimitPerRankPower = params.spendingLimitPerRankPower;
        config.periodDuration = params.periodDuration;
        config.minRank = params.minRank;

        emit MemberTreasurerUpdated(
            params.memberId,
            params.baseSpendingLimit,
            params.spendingLimitPerRankPower,
            params.periodDuration,
            params.minRank
        );
    }

    function _executeRemoveMemberTreasurer(bytes memory data) internal {
        uint32 memberId = abi.decode(data, (uint32));
        
        if (!memberTreasurers[memberId].active) revert TreasurerNotActive();

        delete memberTreasurers[memberId];
        delete memberTreasurerSpending[memberId];

        emit MemberTreasurerRemoved(memberId);
    }

    function _executeSetMemberTreasurerTokenConfig(bytes memory data) internal {
        MemberTokenConfigParams memory params = abi.decode(data, (MemberTokenConfigParams));
        
        if (!memberTreasurers[params.memberId].active) revert TreasurerNotActive();

        memberTreasurerTokenConfigs[params.memberId][params.token] = TokenSpendingConfig({
            hasLimit: true,
            baseLimit: params.baseLimit,
            limitPerRankPower: params.limitPerRankPower
        });

        emit MemberTreasurerTokenConfigSet(params.memberId, params.token, params.baseLimit, params.limitPerRankPower);
    }

    function _executeAddAddressTreasurer(bytes memory data) internal {
        AddressTreasurerParams memory params = abi.decode(data, (AddressTreasurerParams));
        
        if (addressTreasurers[params.treasurer].active) revert TreasurerAlreadyExists();
        
        // Validate spending limits are within bounds (M-04)
        if (params.baseSpendingLimit > MAX_SPENDING_LIMIT) revert SpendingLimitTooHigh();

        addressTreasurers[params.treasurer] = TreasurerConfig({
            active: true,
            treasurerType: TreasurerType.AddressBased,
            baseSpendingLimit: params.baseSpendingLimit,
            spendingLimitPerRankPower: 0,
            periodDuration: params.periodDuration,
            minRank: IRankedMembershipDAO.Rank.G
        });

        emit AddressTreasurerAdded(params.treasurer, params.baseSpendingLimit, params.periodDuration);
    }

    function _executeUpdateAddressTreasurer(bytes memory data) internal {
        AddressTreasurerParams memory params = abi.decode(data, (AddressTreasurerParams));
        
        if (!addressTreasurers[params.treasurer].active) revert TreasurerNotActive();
        
        // Validate spending limits are within bounds (M-04)
        if (params.baseSpendingLimit > MAX_SPENDING_LIMIT) revert SpendingLimitTooHigh();

        TreasurerConfig storage config = addressTreasurers[params.treasurer];
        config.baseSpendingLimit = params.baseSpendingLimit;
        config.periodDuration = params.periodDuration;

        emit AddressTreasurerUpdated(params.treasurer, params.baseSpendingLimit, params.periodDuration);
    }

    function _executeRemoveAddressTreasurer(bytes memory data) internal {
        address treasurer = abi.decode(data, (address));
        
        if (!addressTreasurers[treasurer].active) revert TreasurerNotActive();

        delete addressTreasurers[treasurer];
        delete addressTreasurerSpending[treasurer];

        emit AddressTreasurerRemoved(treasurer);
    }

    function _executeSetAddressTreasurerTokenConfig(bytes memory data) internal {
        AddressTokenConfigParams memory params = abi.decode(data, (AddressTokenConfigParams));
        
        if (!addressTreasurers[params.treasurer].active) revert TreasurerNotActive();

        addressTreasurerTokenConfigs[params.treasurer][params.token] = TokenSpendingConfig({
            hasLimit: true,
            baseLimit: params.limit,
            limitPerRankPower: 0
        });

        emit AddressTreasurerTokenConfigSet(params.treasurer, params.token, params.limit);
    }

    // ----------------------------
    // NFT Execution Helpers
    // ----------------------------

    function _executeTransferNFT(bytes memory data) internal {
        // Check global treasury lock for NFT transfers
        if (treasuryLocked) revert TreasuryLocked();
        
        NFTTransferParams memory params = abi.decode(data, (NFTTransferParams));
        
        // Verify treasury owns this NFT before attempting transfer (M-07)
        try IERC721(params.nftContract).ownerOf(params.tokenId) returns (address owner) {
            if (owner != address(this)) revert NFTNotOwned();
        } catch {
            revert NFTNotOwned();
        }
        
        IERC721(params.nftContract).safeTransferFrom(address(this), params.to, params.tokenId);
        
        emit NFTTransferred(params.nftContract, params.to, params.tokenId);
    }

    function _executeGrantMemberNFTAccess(bytes memory data) internal {
        MemberNFTAccessParams memory params = abi.decode(data, (MemberNFTAccessParams));
        
        // Re-validate at execution time
        (bool exists,,,,) = dao.membersById(params.memberId);
        if (!exists) revert NotMember();
        if (memberNFTAccess[params.memberId][params.nftContract].hasAccess) revert NFTAccessAlreadyGranted();

        memberNFTAccess[params.memberId][params.nftContract] = NFTAccessConfig({
            hasAccess: true,
            transfersPerPeriod: params.transfersPerPeriod,
            periodDuration: params.periodDuration,
            minRank: params.minRank
        });

        emit MemberNFTAccessGranted(
            params.memberId,
            params.nftContract,
            params.transfersPerPeriod,
            params.periodDuration,
            params.minRank
        );
    }

    function _executeRevokeMemberNFTAccess(bytes memory data) internal {
        RevokeNFTAccessParams memory params = abi.decode(data, (RevokeNFTAccessParams));
        
        if (!memberNFTAccess[params.memberId][params.nftContract].hasAccess) revert NFTAccessNotGranted();

        delete memberNFTAccess[params.memberId][params.nftContract];
        delete memberNFTTracking[params.memberId][params.nftContract];

        emit MemberNFTAccessRevoked(params.memberId, params.nftContract);
    }

    function _executeGrantAddressNFTAccess(bytes memory data) internal {
        AddressNFTAccessParams memory params = abi.decode(data, (AddressNFTAccessParams));
        
        if (addressNFTAccess[params.treasurer][params.nftContract].hasAccess) revert NFTAccessAlreadyGranted();

        addressNFTAccess[params.treasurer][params.nftContract] = NFTAccessConfig({
            hasAccess: true,
            transfersPerPeriod: params.transfersPerPeriod,
            periodDuration: params.periodDuration,
            minRank: IRankedMembershipDAO.Rank.G // Not used for address-based
        });

        emit AddressNFTAccessGranted(
            params.treasurer,
            params.nftContract,
            params.transfersPerPeriod,
            params.periodDuration
        );
    }

    function _executeRevokeAddressNFTAccess(bytes memory data) internal {
        RevokeNFTAccessParams memory params = abi.decode(data, (RevokeNFTAccessParams));
        
        if (!addressNFTAccess[params.treasurer][params.nftContract].hasAccess) revert NFTAccessNotGranted();

        delete addressNFTAccess[params.treasurer][params.nftContract];
        delete addressNFTTracking[params.treasurer][params.nftContract];

        emit AddressNFTAccessRevoked(params.treasurer, params.nftContract);
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

    /// @notice Check if treasury owns a specific NFT
    function ownsNFT(address nftContract, uint256 tokenId) external view returns (bool) {
        try IERC721(nftContract).ownerOf(tokenId) returns (address owner) {
            return owner == address(this);
        } catch {
            return false;
        }
    }

    /// @notice Get member NFT access config for a collection
    function getMemberNFTAccess(uint32 memberId, address nftContract) external view returns (NFTAccessConfig memory) {
        return memberNFTAccess[memberId][nftContract];
    }

    /// @notice Get address NFT access config for a collection
    function getAddressNFTAccess(address treasurer, address nftContract) external view returns (NFTAccessConfig memory) {
        return addressNFTAccess[treasurer][nftContract];
    }

    /// @notice Get remaining NFT transfers for a member treasurer
    function getMemberNFTRemainingTransfers(uint32 memberId, address nftContract) external view returns (uint64 remaining) {
        NFTAccessConfig storage config = memberNFTAccess[memberId][nftContract];
        if (!config.hasAccess) return 0;
        if (config.transfersPerPeriod == 0) return type(uint64).max; // Unlimited

        NFTAccessTracking storage tracking = memberNFTTracking[memberId][nftContract];
        uint64 currentTime = uint64(block.timestamp);

        if (config.periodDuration > 0 && currentTime >= tracking.periodStart + config.periodDuration) {
            return config.transfersPerPeriod; // Period reset
        }

        if (config.transfersPerPeriod > tracking.transfersInPeriod) {
            return config.transfersPerPeriod - tracking.transfersInPeriod;
        }
        return 0;
    }

    /// @notice Get remaining NFT transfers for an address treasurer
    function getAddressNFTRemainingTransfers(address treasurer, address nftContract) external view returns (uint64 remaining) {
        NFTAccessConfig storage config = addressNFTAccess[treasurer][nftContract];
        if (!config.hasAccess) return 0;
        if (config.transfersPerPeriod == 0) return type(uint64).max; // Unlimited

        NFTAccessTracking storage tracking = addressNFTTracking[treasurer][nftContract];
        uint64 currentTime = uint64(block.timestamp);

        if (config.periodDuration > 0 && currentTime >= tracking.periodStart + config.periodDuration) {
            return config.transfersPerPeriod; // Period reset
        }

        if (config.transfersPerPeriod > tracking.transfersInPeriod) {
            return config.transfersPerPeriod - tracking.transfersInPeriod;
        }
        return 0;
    }

    /// @notice Check if an address has NFT access for a specific collection
    function hasNFTAccess(address spender, address nftContract) external view returns (bool, TreasurerType) {
        (TreasurerType tType,, bool canTransfer) = _checkNFTAccess(spender, nftContract);
        return (canTransfer, tType);
    }

    // ----------------------------
    // Governance Parameter Views (forwarded from DAO)
    // ----------------------------

    /// @notice Get current voting period (from DAO governance)
    function getVotingPeriod() external view returns (uint64) {
        return dao.votingPeriod();
    }

    /// @notice Get current quorum in basis points (from DAO governance)
    function getQuorumBps() external view returns (uint16) {
        return dao.quorumBps();
    }

    /// @notice Get current execution delay (from DAO governance)
    function getExecutionDelay() external view returns (uint64) {
        return dao.executionDelay();
    }

    // ----------------------------
    // Settings Execution Helpers
    // ----------------------------

    function _executeSetCallActionsEnabled(bytes memory data) internal {
        bool enabled = abi.decode(data, (bool));
        callActionsEnabled = enabled;
        emit CallActionsEnabledSet(enabled);
    }

    function _executeSetTreasurerCallsEnabled(bytes memory data) internal {
        bool enabled = abi.decode(data, (bool));
        treasurerCallsEnabled = enabled;
        emit TreasurerCallsEnabledSet(enabled);
    }

    function _executeAddApprovedCallTarget(bytes memory data) internal {
        address target = abi.decode(data, (address));
        if (approvedCallTargets[target]) revert CallTargetAlreadyApproved();
        approvedCallTargets[target] = true;
        emit ApprovedCallTargetAdded(target);
    }

    function _executeRemoveApprovedCallTarget(bytes memory data) internal {
        address target = abi.decode(data, (address));
        if (!approvedCallTargets[target]) revert CallTargetNotInWhitelist();
        approvedCallTargets[target] = false;
        emit ApprovedCallTargetRemoved(target);
    }

    function _executeSetTreasuryLocked(bytes memory data) internal {
        bool locked = abi.decode(data, (bool));
        treasuryLocked = locked;
        emit TreasuryLockedSet(locked);
    }
}
