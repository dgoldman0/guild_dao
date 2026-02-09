// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    RankedMembershipDAO — Core membership registry.

    Holds:
      - Member data (id, rank, authority, joinedAt)
      - Voting power snapshots (per-member + total, using OZ Checkpoints)
      - Rank math helpers (votingPowerOfRank, inviteAllowanceOfRank, proposalLimitOfRank)
      - Configurable governance parameters (votingPeriod, quorumBps, etc.)
      - Bootstrap controls for initial member seeding
      - Controller authorization: a single GovernanceController address that may
        mutate ranks, authorities, add members, and update governance params.

    The GovernanceController is set once via `setController()` (owner-only) and
    afterwards all privileged mutations flow through it.  MembershipTreasury
    reads this contract through the IRankedMembershipDAO interface.
*/

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RankedMembershipDAO is Ownable, Pausable, ReentrancyGuard, IERC721Receiver {
    using SafeCast for uint256;
    using Checkpoints for Checkpoints.Trace224;
    using SafeERC20 for IERC20;

    // ================================================================
    //                        CONSTANTS
    // ================================================================

    uint64 public constant EPOCH = 100 days;

    // Bounds for configurable parameters
    uint64 public constant MIN_INVITE_EXPIRY   = 1 hours;
    uint64 public constant MAX_INVITE_EXPIRY   = 7 days;
    uint64 public constant MIN_ORDER_DELAY     = 1 hours;
    uint64 public constant MAX_ORDER_DELAY     = 7 days;
    uint64 public constant MIN_VOTING_PERIOD   = 1 days;
    uint64 public constant MAX_VOTING_PERIOD   = 30 days;
    uint16 public constant MIN_QUORUM_BPS      = 500;   // 5%
    uint16 public constant MAX_QUORUM_BPS      = 5000;  // 50%
    uint64 public constant MIN_EXECUTION_DELAY = 1 hours;
    uint64 public constant MAX_EXECUTION_DELAY = 7 days;

    // ================================================================
    //                   GOVERNANCE PARAMETERS
    // ================================================================

    uint64 public inviteExpiry   = 24 hours;
    uint64 public orderDelay     = 24 hours;
    uint64 public votingPeriod   = 7 days;
    uint16 public quorumBps      = 2000; // 20%
    uint64 public executionDelay = 24 hours;

    // ================================================================
    //                  FEE CONFIGURATION
    // ================================================================

    address public feeToken;            // address(0) = ETH, otherwise ERC-20
    uint256 public baseFee;             // per-epoch base fee (scales by rank)
    uint64  public gracePeriod;         // seconds of grace before deactivation (0 = immediate)
    address public payoutTreasury;      // where fee revenue is sent

    // ================================================================
    //                          RANKS
    // ================================================================

    enum Rank { G, F, E, D, C, B, A, S, SS, SSS }

    function _rankIndex(Rank r) internal pure returns (uint8) {
        return uint8(r);
    }

    function votingPowerOfRank(Rank r) public pure returns (uint224) {
        return uint224(1 << _rankIndex(r));
    }

    function inviteAllowanceOfRank(Rank r) public pure returns (uint16) {
        if (r < Rank.F) return 0;
        return uint16(1 << (_rankIndex(r) - _rankIndex(Rank.F)));
    }

    function proposalLimitOfRank(Rank r) public pure returns (uint8) {
        if (r < Rank.F) return 0;
        return uint8(1 + (_rankIndex(r) - _rankIndex(Rank.F)));
    }

    function orderLimitOfRank(Rank r) public pure returns (uint8) {
        if (r < Rank.E) return 0;           // G, F cannot issue orders
        return uint8(1 << (_rankIndex(r) - _rankIndex(Rank.E)));  // E=1, D=2, C=4, B=8, …
    }

    // ================================================================
    //                          ERRORS
    // ================================================================

    error NotMember();
    error AlreadyMember();
    error InvalidAddress();
    error InvalidTarget();
    error BootstrapAlreadyFinalized();
    error FundsNotAccepted();
    error NotController();
    error NotFeeRouter();
    error ParameterOutOfBounds();
    error MemberNotExpired();
    error AlreadyInactive();

    // ================================================================
    //                        MEMBERSHIP
    // ================================================================

    struct Member {
        bool exists;
        uint32 id;
        Rank rank;
        address authority;
        uint64 joinedAt;
    }

    uint32 public nextMemberId = 1;
    mapping(uint32 => Member) public membersById;
    mapping(address => uint32) public memberIdByAuthority;

    // Voting power snapshot checkpoints
    mapping(uint32 => Checkpoints.Trace224) private _memberPower;
    Checkpoints.Trace224 private _totalPower;

    // ================================================================
    //                     MEMBERSHIP FEES
    // ================================================================

    mapping(uint32 => bool)   public memberActive;
    mapping(uint32 => uint64) public feePaidUntil;

    // ================================================================
    //                        BOOTSTRAP
    // ================================================================

    bool public bootstrapFinalized;

    // ================================================================
    //                   CONTROLLER (GovernanceController)
    // ================================================================

    address public controller;

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    // ================================================================
    //                   FEE ROUTER (for fee payments)
    // ================================================================

    address public feeRouter;

    modifier onlyFeeRouter() {
        if (msg.sender != feeRouter) revert NotFeeRouter();
        _;
    }

    // ================================================================
    //                          EVENTS
    // ================================================================

    event BootstrapMember(uint32 indexed memberId, address indexed authority, Rank rank);
    event BootstrapFinalized();
    event ControllerSet(address indexed controller);

    event MemberJoined(uint32 indexed memberId, address indexed authority, Rank rank);
    event AuthorityChanged(
        uint32 indexed memberId,
        address indexed oldAuthority,
        address indexed newAuthority,
        uint32 byMemberId,
        bool viaGovernance
    );
    event RankChanged(
        uint32 indexed memberId,
        Rank oldRank,
        Rank newRank,
        uint32 byMemberId,
        bool viaGovernance
    );

    event VotingPeriodChanged(uint64 oldValue, uint64 newValue);
    event QuorumBpsChanged(uint16 oldValue, uint16 newValue);
    event OrderDelayChanged(uint64 oldValue, uint64 newValue);
    event InviteExpiryChanged(uint64 oldValue, uint64 newValue);
    event ExecutionDelayChanged(uint64 oldValue, uint64 newValue);
    event FeeRouterSet(address indexed feeRouter);
    event FeeTokenChanged(address indexed oldToken, address indexed newToken);
    event BaseFeeChanged(uint256 oldValue, uint256 newValue);
    event GracePeriodChanged(uint64 oldValue, uint64 newValue);
    event PayoutTreasuryChanged(address indexed oldPayout, address indexed newPayout);
    event FeePaid(uint32 indexed memberId, uint64 paidUntil);
    event MemberDeactivated(uint32 indexed memberId);
    event MemberReactivated(uint32 indexed memberId);

    // ================================================================
    //                        CONSTRUCTOR
    // ================================================================

    constructor() Ownable(msg.sender) {
        _bootstrapMember(msg.sender, Rank.SSS);
    }

    // ================================================================
    //                  OWNER-ONLY ADMIN
    // ================================================================

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function bootstrapAddMember(address authority, Rank rank) external onlyOwner {
        _bootstrapMember(authority, rank);
    }

    function finalizeBootstrap() external onlyOwner {
        bootstrapFinalized = true;
        emit BootstrapFinalized();
        renounceOwnership();
    }

    /// @notice Set the GovernanceController address.
    ///         Callable by the owner (during bootstrap) or by the current controller
    ///         (to migrate to a new controller via governance).
    function setController(address _controller) external {
        if (msg.sender != owner() && msg.sender != controller) revert NotController();
        if (_controller == address(0)) revert InvalidAddress();
        controller = _controller;
        emit ControllerSet(_controller);
    }

    /// @notice Set the FeeRouter address (authorized to call recordFeePayment).
    ///         Callable by the owner (during bootstrap) or by the current controller.
    function setFeeRouter(address _feeRouter) external {
        if (msg.sender != owner() && msg.sender != controller) revert NotController();
        if (_feeRouter == address(0)) revert InvalidAddress();
        feeRouter = _feeRouter;
        emit FeeRouterSet(_feeRouter);
    }

    // ================================================================
    //      CONTROLLER-ONLY MUTATIONS (called by GovernanceController)
    // ================================================================

    /// @notice Set a member's rank. Only callable by the controller.
    function setRank(uint32 memberId, Rank newRank, uint32 byMemberId, bool viaGovernance)
        external
        onlyController
    {
        _setRank(memberId, newRank, byMemberId, viaGovernance);
    }

    /// @notice Set a member's authority address. Only callable by the controller.
    function setAuthority(uint32 memberId, address newAuthority, uint32 byMemberId, bool viaGovernance)
        external
        onlyController
    {
        _setAuthority(memberId, newAuthority, byMemberId, viaGovernance);
    }

    /// @notice Register a new member at rank G. Only callable by the controller (invite flow).
    /// @return newMemberId The ID of the newly created member.
    function addMember(address authority) external onlyController returns (uint32 newMemberId) {
        if (authority == address(0)) revert InvalidAddress();
        if (memberIdByAuthority[authority] != 0) revert AlreadyMember();

        newMemberId = nextMemberId++;
        membersById[newMemberId] = Member({
            exists: true,
            id: newMemberId,
            rank: Rank.G,
            authority: authority,
            joinedAt: uint64(block.timestamp)
        });
        memberIdByAuthority[authority] = newMemberId;
        memberActive[newMemberId] = true;
        feePaidUntil[newMemberId] = uint64(block.timestamp) + EPOCH;  // first epoch free
        uint224 p = votingPowerOfRank(Rank.G);
        _writeMemberPower(newMemberId, p);
        _writeTotalPower(totalVotingPower() + p);

        emit MemberJoined(newMemberId, authority, Rank.G);
    }

    // --- Governance parameter setters (controller-only) ---

    function setVotingPeriod(uint64 newValue) external onlyController {
        if (newValue < MIN_VOTING_PERIOD || newValue > MAX_VOTING_PERIOD) revert ParameterOutOfBounds();
        uint64 old = votingPeriod;
        votingPeriod = newValue;
        emit VotingPeriodChanged(old, newValue);
    }

    function setQuorumBps(uint16 newValue) external onlyController {
        if (newValue < MIN_QUORUM_BPS || newValue > MAX_QUORUM_BPS) revert ParameterOutOfBounds();
        uint16 old = quorumBps;
        quorumBps = newValue;
        emit QuorumBpsChanged(old, newValue);
    }

    function setOrderDelay(uint64 newValue) external onlyController {
        if (newValue < MIN_ORDER_DELAY || newValue > MAX_ORDER_DELAY) revert ParameterOutOfBounds();
        uint64 old = orderDelay;
        orderDelay = newValue;
        emit OrderDelayChanged(old, newValue);
    }

    function setInviteExpiry(uint64 newValue) external onlyController {
        if (newValue < MIN_INVITE_EXPIRY || newValue > MAX_INVITE_EXPIRY) revert ParameterOutOfBounds();
        uint64 old = inviteExpiry;
        inviteExpiry = newValue;
        emit InviteExpiryChanged(old, newValue);
    }

    function setExecutionDelay(uint64 newValue) external onlyController {
        if (newValue < MIN_EXECUTION_DELAY || newValue > MAX_EXECUTION_DELAY) revert ParameterOutOfBounds();
        uint64 old = executionDelay;
        executionDelay = newValue;
        emit ExecutionDelayChanged(old, newValue);
    }

    /// @notice Transfer ERC20 tokens held by this contract (e.g. accidental deposits).
    ///         Only callable by the controller (via governance vote).
    function transferERC20(address token, address recipient, uint256 amount) external onlyController {
        if (token == address(0) || recipient == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(recipient, amount);
    }

    /// @notice Set the ERC-20 fee token (address(0) = ETH).
    ///         Callable by the owner (during bootstrap) or by the current controller.
    function setFeeToken(address newToken) external {
        if (msg.sender != owner() && msg.sender != controller) revert NotController();
        address old = feeToken;
        feeToken = newToken;
        emit FeeTokenChanged(old, newToken);
    }

    /// @notice Set base fee (per-epoch, scales by rank).
    ///         Callable by the owner (during bootstrap) or by the current controller.
    function setBaseFee(uint256 newValue) external {
        if (msg.sender != owner() && msg.sender != controller) revert NotController();
        uint256 old = baseFee;
        baseFee = newValue;
        emit BaseFeeChanged(old, newValue);
    }

    /// @notice Set grace period (seconds after fee expiry before deactivation).
    ///         Callable by the owner (during bootstrap) or by the current controller.
    function setGracePeriod(uint64 newValue) external {
        if (msg.sender != owner() && msg.sender != controller) revert NotController();
        uint64 old = gracePeriod;
        gracePeriod = newValue;
        emit GracePeriodChanged(old, newValue);
    }

    /// @notice Set the address that receives fee revenue.
    ///         Callable by the owner (during bootstrap) or by the current controller.
    function setPayoutTreasury(address newPayout) external {
        if (msg.sender != owner() && msg.sender != controller) revert NotController();
        if (newPayout == address(0)) revert InvalidAddress();
        address old = payoutTreasury;
        payoutTreasury = newPayout;
        emit PayoutTreasuryChanged(old, newPayout);
    }

    /// @notice Governance override to set member active status.
    function setMemberActive(uint32 memberId, bool _active) external onlyController {
        Member storage m = membersById[memberId];
        if (!m.exists) revert InvalidTarget();

        if (_active && !memberActive[memberId]) {
            memberActive[memberId] = true;
            uint224 power = votingPowerOfRank(m.rank);
            _writeMemberPower(memberId, power);
            _writeTotalPower(totalVotingPower() + power);
            emit MemberReactivated(memberId);
        } else if (!_active && memberActive[memberId]) {
            memberActive[memberId] = false;
            uint224 power = votingPowerOfRank(m.rank);
            _writeMemberPower(memberId, 0);
            _writeTotalPower(totalVotingPower() - power);
            emit MemberDeactivated(memberId);
        }
    }

    // ================================================================
    //    FEE-ROUTER-ONLY (called by FeeRouter after collecting payment)
    // ================================================================

    /// @notice Record a fee payment.  Extends feePaidUntil and reactivates if needed.
    ///         Only callable by the fee router contract (after it has collected the fee).
    function recordFeePayment(uint32 memberId) external onlyFeeRouter {
        Member storage m = membersById[memberId];
        if (!m.exists) revert InvalidTarget();

        uint64 paidUntil = feePaidUntil[memberId];
        if (paidUntil < uint64(block.timestamp)) {
            feePaidUntil[memberId] = uint64(block.timestamp) + EPOCH;
        } else {
            feePaidUntil[memberId] = paidUntil + EPOCH;
        }

        if (!memberActive[memberId]) {
            memberActive[memberId] = true;
            uint224 power = votingPowerOfRank(m.rank);
            _writeMemberPower(memberId, power);
            _writeTotalPower(totalVotingPower() + power);
            emit MemberReactivated(memberId);
        }

        emit FeePaid(memberId, feePaidUntil[memberId]);
    }

    // ================================================================
    //      PERMISSIONLESS FEE ENFORCEMENT
    // ================================================================

    /// @notice Deactivate a member whose fee has expired (+ grace).  Anyone can call.
    function deactivateMember(uint32 memberId) external {
        Member storage m = membersById[memberId];
        if (!m.exists) revert InvalidTarget();
        if (!memberActive[memberId]) revert AlreadyInactive();
        if (block.timestamp <= uint256(feePaidUntil[memberId]) + uint256(gracePeriod))
            revert MemberNotExpired();

        memberActive[memberId] = false;
        uint224 power = votingPowerOfRank(m.rank);
        _writeMemberPower(memberId, 0);
        _writeTotalPower(totalVotingPower() - power);

        emit MemberDeactivated(memberId);
    }

    // ================================================================
    //     SELF-SERVICE (called by member authorities directly)
    // ================================================================

    /// @notice A member can change their own authority address (immediate, no timelock).
    function changeMyAuthority(address newAuthority) external whenNotPaused nonReentrant {
        uint32 memberId = _requireMemberAuthority(msg.sender);
        _setAuthority(memberId, newAuthority, memberId, false);
    }

    // ================================================================
    //                      VIEW FUNCTIONS
    // ================================================================

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

    function myMemberId() external view returns (uint32) {
        return memberIdByAuthority[msg.sender];
    }

    function getMember(uint32 memberId) external view returns (Member memory) {
        return membersById[memberId];
    }

    /// @notice Check if an address is a current member authority
    function isMemberAuthority(address who) external view returns (bool) {
        uint32 id = memberIdByAuthority[who];
        return id != 0 && membersById[id].exists && membersById[id].authority == who;
    }

    /// @notice Fee for one epoch at a given rank: baseFee × 2^rankIndex.
    function feeOfRank(Rank r) public view returns (uint256) {
        return baseFee * (1 << _rankIndex(r));
    }

    /// @notice Whether a member is currently active.
    function isMemberActive(uint32 memberId) public view returns (bool) {
        return memberActive[memberId];
    }

    // ================================================================
    //                    INTERNAL HELPERS
    // ================================================================

    function _requireMemberAuthority(address who) internal view returns (uint32 memberId) {
        memberId = memberIdByAuthority[who];
        if (memberId == 0 || !membersById[memberId].exists) revert NotMember();
        if (membersById[memberId].authority != who) revert NotMember();
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

        m.rank = newRank;

        // Only adjust voting power if member is active
        if (memberActive[memberId]) {
            uint224 oldP = votingPowerOfRank(old);
            uint224 newP = votingPowerOfRank(newRank);
            _writeMemberPower(memberId, newP);

            uint224 total = totalVotingPower();
            if (newP > oldP) {
                total += (newP - oldP);
            } else {
                total -= (oldP - newP);
            }
            _writeTotalPower(total);
        }

        emit RankChanged(memberId, old, newRank, byMemberId, viaGovernance);
    }

    function _setAuthority(uint32 memberId, address newAuthority, uint32 byMemberId, bool viaGovernance) internal {
        if (newAuthority == address(0)) revert InvalidAddress();

        Member storage m = membersById[memberId];
        if (!m.exists) revert InvalidTarget();
        if (memberIdByAuthority[newAuthority] != 0) revert AlreadyMember();

        address old = m.authority;
        memberIdByAuthority[old] = 0;
        memberIdByAuthority[newAuthority] = memberId;
        m.authority = newAuthority;

        emit AuthorityChanged(memberId, old, newAuthority, byMemberId, viaGovernance);
    }

    function _bootstrapMember(address authority, Rank rank) internal {
        if (bootstrapFinalized) revert BootstrapAlreadyFinalized();
        if (authority == address(0)) revert InvalidAddress();
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
        memberActive[id] = true;
        feePaidUntil[id] = type(uint64).max;   // bootstrap members never expire

        uint224 p = votingPowerOfRank(rank);
        _writeMemberPower(id, p);
        _writeTotalPower(totalVotingPower() + p);

        emit BootstrapMember(id, authority, rank);
    }

    // ================================================================
    //          FUND REJECTION & ERC-721 RECEIVER
    // ================================================================

    receive() external payable {
        revert FundsNotAccepted();
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert FundsNotAccepted();
    }

    fallback() external payable {
        revert FundsNotAccepted();
    }
}
