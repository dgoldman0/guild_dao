# Security Audit Report: Guild DAO Contracts

**Audit Date:** January 18, 2026  
**Contracts Audited:**
- `RankedMembershipDAO.sol` (946 lines)
- `MembershipTreasury.sol` (2035 lines)

**Solidity Version:** ^0.8.24  
**Dependencies:** OpenZeppelin Contracts v5+

---

## Executive Summary

This audit covers a ranked membership DAO system with an associated treasury. The DAO implements a hierarchical rank system (G through SSS) with timelocked orders, governance proposals, and an invite mechanism. The treasury supports ETH/ERC20/NFT management with a sophisticated treasurer system for delegated spending.

### Overall Risk Assessment

| Category | Rating |
|----------|--------|
| **Critical** | 2 |
| **High** | 5 |
| **Medium** | 8 |
| **Low** | 12 |
| **Informational** | 10 |

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Critical Issues](#critical-issues)
3. [High Severity Issues](#high-severity-issues)
4. [Medium Severity Issues](#medium-severity-issues)
5. [Low Severity Issues](#low-severity-issues)
6. [Informational & Gas Optimizations](#informational--gas-optimizations)
7. [Code Quality Analysis](#code-quality-analysis)
8. [Recommendations](#recommendations)

---

## Architecture Overview

### RankedMembershipDAO.sol

The DAO contract implements:
- **Rank System:** 10 ranks (G to SSS) with exponential voting power (2^rankIndex)
- **Invite System:** Epoch-based invite allowances with 24h expiry
- **Timelocked Orders:** Promotions, demotions, and authority changes with 24h delay
- **Governance:** Snapshot-based voting with 7-day voting period and 20% quorum
- **Bootstrap:** Initial member seeding before finalization

### MembershipTreasury.sol

The treasury contract implements:
- **Asset Management:** ETH, ERC20, and NFT deposits/transfers
- **Proposal System:** Governance-controlled treasury actions
- **Treasurer System:** Delegated spending with rate limits (member-based and address-based)
- **NFT Access Control:** Per-collection access grants for treasurers
- **Call Whitelist:** Approved external contract interactions
- **Spend Caps:** Optional daily spending limits

---

## Critical Issues

### C-01: Missing Return Value Check on ERC20 Transfer

**Location:** `MembershipTreasury.sol` - Lines 485, 1642

**Description:** The `IERC20.transfer()` call does not check the return value. Some ERC20 tokens (like USDT) don't revert on failure but return `false`.

```solidity
// Line 485
IERC20(token).transfer(to, amount);

// Line 1642
IERC20(p.action.token).transfer(p.action.target, p.action.value);
```

**Impact:** Tokens may fail to transfer silently, leading to accounting errors and potential loss of funds.

**Recommendation:** Use OpenZeppelin's `SafeERC20` library:

```solidity
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

using SafeERC20 for IERC20;

// Then use:
IERC20(token).safeTransfer(to, amount);
```

---

### C-02: Unchecked External Call Return Value for depositERC20

**Location:** `MembershipTreasury.sol` - Line 439

**Description:** `transferFrom` return value is not checked.

```solidity
IERC20(token).transferFrom(msg.sender, address(this), amount);
```

**Impact:** Deposit may appear successful when tokens weren't actually transferred.

**Recommendation:** Use `safeTransferFrom`:

```solidity
IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
```

---

## High Severity Issues

### H-01: Reentrancy Risk in Treasurer Spending Functions

**Location:** `MembershipTreasury.sol` - `treasurerSpendETH()`, `treasurerSpendERC20()`, `treasurerCall()`

**Description:** While `ReentrancyGuard` is used, the spending limit is recorded BEFORE the external call. If the external call somehow reverts after partial execution (e.g., via a callback), the spending record remains.

```solidity
function treasurerSpendETH(address to, uint256 amount) external whenNotPaused nonReentrant {
    // ...
    _checkAndRecordTreasurerSpending(...); // Records spending FIRST
    (bool ok,) = to.call{value: amount}("");  // Then transfers
    if (!ok) revert ExecutionFailed();
}
```

**Impact:** In edge cases with complex receiver contracts, spending limits could be incorrectly tracked.

**Recommendation:** Consider the checks-effects-interactions pattern more strictly or verify the call succeeded before recording is finalized. The current implementation with `nonReentrant` is mostly safe, but adding explicit revert handling would strengthen it.

---

### H-02: Proposal Can Be Executed Even If callActionsEnabled Changed

**Location:** `MembershipTreasury.sol` - `execute()` function, Line 1640

**Description:** A `Call` action proposal might be created when `callActionsEnabled = true`, pass voting, but by execution time `callActionsEnabled` might be `false`, causing the proposal to revert.

```solidity
} else if (p.action.actionType == ActionType.Call) {
    if (!callActionsEnabled) revert ActionDisabled();
```

**Impact:** Passed proposals may become unexecutable, wasting governance effort. Conversely, this could be intentional as a safety mechanism.

**Recommendation:** Document this as intended behavior OR lock the setting at proposal creation time by storing it in the proposal struct.

---

### H-03: Missing Validation in Bootstrap Member Addition

**Location:** `RankedMembershipDAO.sol` - `_bootstrapMember()`, Line 369

**Description:** The function uses an unnamed `revert()` when `bootstrapFinalized` is true.

```solidity
function _bootstrapMember(address authority, Rank rank) internal {
    if (bootstrapFinalized) revert(); // Unnamed revert
    // ...
}
```

**Impact:** Poor error messaging makes debugging difficult. Gas is wasted as no specific error is thrown.

**Recommendation:** Use a named error:

```solidity
error BootstrapAlreadyFinalized();

if (bootstrapFinalized) revert BootstrapAlreadyFinalized();
```

---

### H-04: Owner Centralization Risk

**Location:** Both contracts

**Description:** The `onlyOwner` functions have significant power:
- `MembershipTreasury`: `pause()`, `unpause()`, `setCapsEnabled()`, `setDailyCap()`
- `RankedMembershipDAO`: `pause()`, `unpause()`, `bootstrapAddMember()`, `finalizeBootstrap()`

**Impact:** Single owner has excessive control. If owner key is compromised, attacker can:
- Pause all operations indefinitely
- Add arbitrary members during bootstrap
- Set arbitrary spending caps

**Recommendation:**
1. Transfer ownership to a multisig or DAO governance after deployment
2. Consider timelocked admin functions
3. Add emergency timelock on pause to prevent indefinite lockout

---

### H-05: Front-Running Vulnerability on Invite Claims

**Location:** `RankedMembershipDAO.sol` - `issueInvite()`, `acceptInvite()`

**Description:** Invites are issued to a specific address, but the invite ID is publicly visible. A malicious observer could potentially:
1. Monitor for `InviteIssued` events
2. Front-run the intended recipient's `acceptInvite()` call

However, since invites are bound to a specific address (`inv.to != msg.sender` check), this is mitigated.

**Impact:** Low actual risk due to address binding, but invite details are publicly visible which could be a privacy concern.

**Recommendation:** No code change needed, but document that invite issuance is public information.

---

## Medium Severity Issues

### M-01: Proposal Limit Not Updated on Rank Change

**Location:** `RankedMembershipDAO.sol`

**Description:** If a member's rank changes while they have active proposals, their `activeProposalsOf` count doesn't adjust relative to their new rank's limit.

**Example:**
1. Member at rank E (limit 2) creates 2 proposals
2. Member gets demoted to F (limit 1)
3. Member now has 2 active proposals but limit is 1
4. No enforcement until next proposal attempt

**Impact:** Members may temporarily exceed their proposal limit after demotion.

**Recommendation:** Accept as intended behavior (proposals already created remain valid) or add enforcement logic on rank changes.

---

### M-02: Spending Period Reset Edge Case

**Location:** `MembershipTreasury.sol` - `_checkAndRecordTreasurerSpending()`

**Description:** When the spending period resets, only the current token's spending is reset, not all tokens:

```solidity
if (currentTime >= periodStart + periodDuration) {
    spending.periodStart = currentTime;
    spending.spentInPeriod = 0;
    // Reset token spending too
    memberTreasurerTokenSpent[memberId][token] = 0; // Only THIS token
    spentInPeriod = 0;
}
```

**Impact:** If a treasurer spends Token A, then later spends Token B in a new period, Token A's spent amount persists until Token A is spent again.

**Recommendation:** This is likely by design (per-token tracking), but consider documenting clearly. Alternatively, implement a global period reset mechanism.

---

### M-03: Rank Comparison Uses Unsafe Enum Comparison

**Location:** `RankedMembershipDAO.sol` - Multiple locations

**Description:** Rank comparisons use `<`, `>`, `<=`, `>=` operators on enums, which works in Solidity 0.8+ but can be confusing.

```solidity
if (rank < config.minRank) return (TreasurerType.None, 0, 0);
```

**Impact:** Code correctness depends on enum order being maintained. Future modifications could introduce bugs.

**Recommendation:** Add explicit comments or use `_rankIndex()` for all comparisons:

```solidity
if (_rankIndex(rank) < _rankIndex(config.minRank)) return (TreasurerType.None, 0, 0);
```

---

### M-04: No Upper Bound on Spending Limits

**Location:** `MembershipTreasury.sol`

**Description:** Treasurer spending limits can be set to arbitrarily high values with no upper cap:

```solidity
memberTreasurers[params.memberId] = TreasurerConfig({
    baseSpendingLimit: params.baseSpendingLimit, // No max check
    // ...
});
```

**Impact:** A malicious or compromised governance could grant unlimited spending power.

**Recommendation:** Consider adding maximum spending limit constants or governance-controlled caps.

---

### M-05: Missing Member Existence Check in Some View Functions

**Location:** `RankedMembershipDAO.sol` - View helpers

**Description:** Functions like `getMember()` return empty structs for non-existent members rather than reverting.

```solidity
function getMember(uint32 memberId) external view returns (Member memory) {
    return membersById[memberId];
}
```

**Impact:** Callers may receive default values and assume member exists.

**Recommendation:** Add existence check or document that callers must verify `exists` field.

---

### M-06: Proposal Snapshot at Current Block

**Location:** Both contracts - Proposal creation functions

**Description:** Snapshot is taken at `block.number.toUint32()` in the same transaction as proposal creation.

```solidity
uint32 snap = block.number.toUint32();
```

**Impact:** Proposer's current voting power is included in snapshot. This is standard practice but could allow minor gaming if proposer receives power in the same block.

**Recommendation:** Consider using `block.number - 1` for snapshot or document this as intended.

---

### M-07: NFT Transfer Doesn't Verify Ownership

**Location:** `MembershipTreasury.sol` - `_executeTransferNFT()`

**Description:** The function attempts to transfer without first verifying the treasury owns the NFT:

```solidity
function _executeTransferNFT(bytes memory data) internal {
    NFTTransferParams memory params = abi.decode(data, (NFTTransferParams));
    IERC721(params.nftContract).safeTransferFrom(address(this), params.to, params.tokenId);
}
```

**Impact:** If NFT was transferred out by another means (treasurer access), proposal execution will revert.

**Recommendation:** Add pre-check or accept that revert is the expected behavior.

---

### M-08: Uncapped Array of ActionTypes

**Location:** `MembershipTreasury.sol`

**Description:** The `ActionType` enum has 21 values and could grow. The `execute()` function uses a long if-else chain:

```solidity
if (p.action.actionType == ActionType.TransferETH) {
    // ...
} else if (p.action.actionType == ActionType.TransferERC20) {
    // ...
} // ... many more
```

**Impact:** Gas costs increase with each new action type. Maintenance becomes error-prone.

**Recommendation:** Consider using a function selector pattern or mapping of action handlers.

---

## Low Severity Issues

### L-01: Event Emission Before State Changes

**Location:** Multiple locations

**Description:** Some events are emitted after state changes (correct), but consistency should be verified throughout.

**Recommendation:** Audit all event emissions to ensure they follow state changes.

---

### L-02: Magic Numbers in Code

**Location:** Both contracts

**Description:** Various magic numbers are used:

```solidity
uint16 public constant QUORUM_BPS = 2000; // 20%
uint64 public constant VOTING_PERIOD = 7 days;
uint64 public constant EXECUTION_DELAY = 24 hours;
```

**Impact:** While documented, the relationship (e.g., 2000 = 20%) requires mental conversion.

**Recommendation:** Add explicit comments or use named constants:

```solidity
uint16 private constant BPS_DENOMINATOR = 10_000;
uint16 public constant QUORUM_BPS = 2000; // 20% = 2000/10000
```

---

### L-03: Potential Integer Overflow in Voting Power Calculation

**Location:** `RankedMembershipDAO.sol` - `votingPowerOfRank()`

**Description:**

```solidity
function votingPowerOfRank(Rank r) public pure returns (uint224) {
    return uint224(1 << _rankIndex(r)); // Max: 1 << 9 = 512
}
```

**Impact:** Currently safe (max 512 for SSS), but if more ranks are added, could overflow.

**Recommendation:** Add bounds checking or document the maximum rank limit.

---

### L-04: Invite Epoch Calculation Could Cause Issues

**Location:** `RankedMembershipDAO.sol`

**Description:**

```solidity
function _currentEpoch() internal view returns (uint64) {
    return uint64(block.timestamp / INVITE_EPOCH);
}
```

**Impact:** Safe for practical purposes, but relies on timestamp behavior.

**Recommendation:** Consider using block numbers for more deterministic behavior.

---

### L-05: Missing Zero Amount Checks

**Location:** Multiple transfer functions

**Description:** Functions allow zero-value transfers:

```solidity
function treasurerSpendETH(address to, uint256 amount) external {
    // No check: if (amount == 0) revert ZeroAmount();
}
```

**Impact:** Wastes gas, clutters event logs.

**Recommendation:** Add zero amount validation.

---

### L-06: Redundant Member Check in Proposal Functions

**Location:** `MembershipTreasury.sol`

**Description:** Member verification is done multiple times:

```solidity
(uint32 proposerId, IRankedMembershipDAO.Rank rank) = _requireMember(msg.sender);
if (rank < IRankedMembershipDAO.Rank.F) revert NotMember(); // Duplicate logic
```

**Impact:** Minor gas waste, code clutter.

**Recommendation:** Consolidate into single check in `_requireMember()`.

---

### L-07: Ownable2Step Not Fully Utilized

**Location:** Both contracts

**Description:** `Ownable2Step` is inherited but `acceptOwnership()` flow isn't documented for users.

**Recommendation:** Add documentation for ownership transfer process.

---

### L-08: No Mechanism to Cancel Proposals

**Location:** Both contracts

**Description:** Once a proposal is created, it cannot be cancelled by the proposer.

**Impact:** Proposers cannot retract proposals even if circumstances change.

**Recommendation:** Consider adding proposal cancellation (by proposer only, before voting ends).

---

### L-09: Precision Loss in Quorum Calculation

**Location:** Both contracts

**Description:**

```solidity
uint256 required = (uint256(totalAtSnap) * QUORUM_BPS) / 10_000;
```

**Impact:** Minor precision loss due to integer division. With small total voting powers, could be exploited.

**Recommendation:** Use ceiling division or add minimum absolute quorum.

---

### L-10: Block Number Cast to uint32

**Location:** Both contracts

**Description:**

```solidity
uint32 snap = block.number.toUint32();
```

**Impact:** Block number overflow at ~4.3 billion blocks. At 12s/block = ~1,630 years. Safe but worth noting.

**Recommendation:** Document the assumption or use uint64.

---

### L-11: Inconsistent Error Naming

**Location:** Both contracts

**Description:** Error names aren't consistent:
- `NotMember()` vs `InvalidTarget()`
- `NotReady()` vs `OrderNotReady()`

**Recommendation:** Standardize error naming convention.

---

### L-12: No Event for Period Reset

**Location:** `MembershipTreasury.sol`

**Description:** When a treasurer's spending period resets, no event is emitted.

**Impact:** Off-chain tracking of spending periods is difficult.

**Recommendation:** Consider emitting `TreasurerPeriodReset` event.

---

## Informational & Gas Optimizations

### I-01: Use Custom Errors Consistently

Both contracts use custom errors (good), but ensure all revert statements use them. The unnamed `revert()` in `_bootstrapMember()` should be replaced.

### I-02: Consider Using Immutable for DAO Reference

```solidity
IRankedMembershipDAO public immutable dao; // Already immutable - good
```

### I-03: Storage Optimization Opportunities

Struct packing could be improved:

```solidity
struct TreasurerConfig {
    bool active;                          // 1 byte
    TreasurerType treasurerType;          // 1 byte
    IRankedMembershipDAO.Rank minRank;    // 1 byte
    uint64 periodDuration;                // 8 bytes
    // Above fits in one slot (11 bytes)
    uint256 baseSpendingLimit;            // 32 bytes (new slot)
    uint256 spendingLimitPerRankPower;    // 32 bytes (new slot)
}
```

Current order may not be optimal.

### I-04: Use `++i` Instead of `i++`

Minor gas savings in loops (none found, but good practice).

### I-05: Cache Storage Variables

In functions that read storage multiple times, cache in memory:

```solidity
// Instead of:
if (config.periodDuration > 0 && currentTime >= tracking.periodStart + config.periodDuration)

// Use:
uint64 periodDuration = config.periodDuration;
uint64 periodStart = tracking.periodStart;
if (periodDuration > 0 && currentTime >= periodStart + periodDuration)
```

### I-06: Add NatSpec Documentation

Functions lack comprehensive NatSpec documentation. Add `@param`, `@return`, and `@notice` for all public functions.

### I-07: Consider EIP-2612 Permit Support

For gasless ERC20 deposits, consider supporting tokens with permit functionality.

### I-08: Missing Interface Definition

`IRankedMembershipDAO` is defined inline. Consider extracting to a separate file.

### I-09: Compiler Version Pinning

Using `^0.8.24` allows flexibility but consider pinning to exact version for production.

### I-10: Test Coverage Recommendations

Ensure comprehensive testing for:
- Edge cases in spending limits (near max, at max, over max)
- Rank boundary conditions (G to SSS transitions)
- Concurrent proposal scenarios
- Period boundary resets

---

## Code Quality Analysis

### Positive Aspects

1. **Use of OpenZeppelin Libraries:** `Ownable2Step`, `Pausable`, `ReentrancyGuard`, `SafeCast`, `Checkpoints` are correctly used
2. **Separation of Concerns:** Clear separation between membership DAO and treasury
3. **Access Control:** Proper rank-based access control with timelocks
4. **Event Emission:** Comprehensive events for off-chain tracking
5. **Custom Errors:** Gas-efficient custom errors instead of strings
6. **Snapshot Voting:** Proper implementation using `Checkpoints.Trace224`

### Areas for Improvement

1. **Documentation:** Add comprehensive NatSpec and inline comments
2. **Error Consistency:** Standardize error naming
3. **Code Organization:** Consider splitting large contracts into libraries
4. **SafeERC20:** Must be implemented for production
5. **Testing:** Ensure edge cases are covered

---

## Recommendations

### Immediate Actions (Pre-Deployment)

1. **CRITICAL:** Implement `SafeERC20` for all ERC20 operations
2. **HIGH:** Add named error to bootstrap revert
3. **HIGH:** Document or implement proposal cancellation mechanism
4. **MEDIUM:** Add zero-amount validation

### Post-Deployment

1. Transfer ownership to a multisig
2. Set reasonable spending caps initially
3. Keep `callActionsEnabled` and `treasurerCallsEnabled` as `false` until needed
4. Monitor for suspicious invite patterns

### Long-term

1. Consider upgradeable proxy pattern for future improvements
2. Implement governance-controlled admin functions
3. Add emergency withdrawal mechanism for stuck funds
4. Consider adding slashing mechanism for malicious treasurers

---

## Conclusion

The Guild DAO contracts demonstrate solid Solidity development practices with proper use of OpenZeppelin libraries and security patterns. The critical issues identified are related to ERC20 token handling, which must be fixed before production deployment. The architecture is well-thought-out with appropriate checks and balances through the rank system and timelocks.

**Recommended Action:** Fix critical and high severity issues before mainnet deployment.

---

*This audit is provided as-is and does not constitute financial or legal advice. A professional security audit firm should be engaged for additional review before production deployment.*
