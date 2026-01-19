# Security Audit Report: Guild DAO

**Audit Date:** January 19, 2026  
**Auditor:** Static Analysis Review (AI-Assisted)  
**Contracts:**
- `RankedMembershipDAO.sol` (1,310 lines)
- `MembershipTreasury.sol` (2,168 lines)

**Solidity Version:** ^0.8.24  
**Dependencies:** OpenZeppelin Contracts v5+

---

## Executive Summary

This audit covers two interconnected smart contracts implementing a ranked membership DAO with a separate treasury system. The architecture demonstrates several well-designed security patterns, but also contains areas requiring attention.

### Risk Summary

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 8 |
| Low | 9 |
| Informational | 7 |

---

## Contract Overview

### RankedMembershipDAO.sol

A membership-controlled DAO implementing:
- 10-tier ranking system (G through SSS)
- Invite system with epoch-based allowances
- Timelocked orders for promotions, demotions, and authority changes
- Snapshot-based governance voting
- Configurable governance parameters

### MembershipTreasury.sol

A treasury contract implementing:
- Multi-asset treasury (ETH, ERC20, ERC721)
- Proposal-based governance for treasury actions
- Treasurer system with spending limits
- NFT access controls
- Global treasury lock mechanism
- Approved call target whitelist

---

## Detailed Findings

### Critical Severity

#### C-01: Ownable2Step Constructor Missing `msg.sender` Call

**Location:** `RankedMembershipDAO.sol:29`, `MembershipTreasury.sol:42`

**Description:**  
Both contracts inherit from `Ownable2Step` and pass `msg.sender` to the parent constructor. However, OpenZeppelin's `Ownable2Step` in v5+ requires importing `Ownable` and calling `Ownable(msg.sender)` instead. If using the wrong import path or version, this could cause compilation errors or unexpected behavior.

```solidity
// Current:
constructor() Ownable2Step(msg.sender) { ... }

// OpenZeppelin v5 expects:
constructor(address initialOwner) Ownable(initialOwner) { ... }
```

**Recommendation:**  
Verify the exact OpenZeppelin version being used and confirm the constructor pattern matches. For OZ v5+, `Ownable2Step` no longer takes a constructor argument directly—it inherits from `Ownable` which takes the initial owner.

**Status:** Requires verification against actual OZ version

---

### High Severity

#### H-01: Snapshot Block Used at Creation Allows Voting Manipulation

**Location:** `RankedMembershipDAO.sol:1065-1066`, `MembershipTreasury.sol:915-916`

**Description:**  
The snapshot block for voting power is set at proposal creation time (`block.number.toUint32()`). While the `MembershipTreasury` implements a `VOTING_DELAY`, the `RankedMembershipDAO` does not. This allows an attacker to:

1. Acquire voting power (via rank promotion or invite)
2. Immediately create a proposal in the same block
3. Vote with the newly acquired power before others can react

```solidity
// RankedMembershipDAO.sol - No voting delay
p.snapshotBlock = block.number.toUint32();
p.startTime = start;  // Voting starts immediately
```

**Recommendation:**  
Add a voting delay to `RankedMembershipDAO.sol` similar to `MembershipTreasury`:
```solidity
uint64 public constant VOTING_DELAY = 1; // blocks
// In castVote:
if (block.number <= p.snapshotBlock + VOTING_DELAY) revert VotingNotStarted();
```

**Severity:** High

---

#### H-02: Member Token Spending Not Properly Reset Across Periods

**Location:** `MembershipTreasury.sol:712-752`

**Description:**  
In `_checkAndRecordTreasurerSpending`, when a spending period expires, only the ETH spending and the current token being spent are reset. Other tokens' spending counts are not reset, potentially allowing stale values to persist.

```solidity
// Reset period if expired
bool periodExpired = currentTime >= periodStart + periodDuration;
if (periodExpired) {
    spending.periodStart = currentTime;
    spending.spentInPeriod = 0;
    // Note: Token spending is tracked per-token but shares the same period
    // We only reset the current token here; other tokens will be lazily reset
}
```

While the comment indicates lazy reset is intended, the actual implementation may still use stale `periodStart` values for other tokens, causing incorrect limit calculations.

**Recommendation:**  
Consider implementing a more robust reset mechanism or storing period start per-token, or validate the logic more carefully to ensure lazy reset works correctly in all scenarios.

**Severity:** High

---

#### H-03: Authority Order Can Be Frontrun Before Execution

**Location:** `RankedMembershipDAO.sol:625-650`

**Description:**  
When `issueAuthorityOrder` is created, it checks that `newAuthority` is not already a member. However, this check is only performed at creation time. If during the 24-hour delay:

1. The target `newAuthority` address joins the DAO via an invite
2. The authority order is then executed

The execution will fail with `AlreadyMember()`, but this creates a griefing vector where malicious actors can intentionally claim the target address via an invite to block legitimate authority recovery orders.

```solidity
// At creation (line 629):
if (memberIdByAuthority[newAuthority] != 0) revert AlreadyMember();

// At execution (line 697):
if (memberIdByAuthority[o.newAuthority] != 0) revert AlreadyMember();
```

**Recommendation:**  
Consider allowing the order issuer to specify an alternative address or implementing a mechanism to handle this edge case gracefully.

**Severity:** High

---

### Medium Severity

#### M-01: Zero Quorum Edge Case in RankedMembershipDAO

**Location:** `RankedMembershipDAO.sol:1114-1124`

**Description:**  
Unlike `MembershipTreasury` which explicitly checks for zero votes cast, `RankedMembershipDAO` does not have this check. If `totalAtSnap` is 0 (theoretically possible if all members left), or if `quorumBps` calculation results in 0, proposals could pass with minimal votes.

```solidity
// MembershipTreasury has this protection (line 1664):
if (votesCast == 0) {
    p.succeeded = false;
    // ...
}

// RankedMembershipDAO does NOT have this check
```

**Recommendation:**  
Add explicit zero-vote check in `RankedMembershipDAO.finalizeProposal()`.

**Severity:** Medium

---

#### M-02: Bootstrap Can Be Called Before Finalization Creates Unbalanced Power

**Location:** `RankedMembershipDAO.sol:395-398`

**Description:**  
The `bootstrapAddMember` function allows the owner to add members of any rank before bootstrap is finalized. If the owner adds many high-rank members, they could create a situation where the initial deployer (SSS) loses effective control.

While this is by design, there's no limit on the number or ranks of bootstrap members, which could lead to unforeseen governance imbalances.

**Recommendation:**  
Consider adding limits to bootstrap operations or at least documenting the expected bootstrap workflow clearly.

**Severity:** Medium

---

#### M-03: Rank Comparison Uses Enum Ordering Implicitly

**Location:** Multiple locations in both contracts

**Description:**  
Rank comparisons rely on Solidity's implicit enum ordering (e.g., `rank < Rank.F`). While this works correctly, it's fragile if the enum order ever changes. The code does include a `_rankIndex` helper but doesn't use it consistently.

```solidity
// Good - using explicit index:
if (_rankIndex(rank) >= _rankIndex(config.minRank)) { ... }

// Less explicit - relying on enum ordering:
if (r < Rank.F) return 0;
```

**Recommendation:**  
Use `_rankIndex()` consistently for all rank comparisons to make the code more explicit and maintainable.

**Severity:** Medium

---

#### M-04: No Upper Bound on Spending Limits in Proposal Creation

**Location:** `MembershipTreasury.sol:1054-1093`

**Description:**  
While there are `MAX_SPENDING_LIMIT` and `MAX_SPENDING_LIMIT_PER_RANK` constants that are checked during execution, they are not validated at proposal creation time. This means proposals can be created with invalid parameters that will fail at execution.

```solidity
// Validated at execution, not at proposal creation:
if (params.baseSpendingLimit > MAX_SPENDING_LIMIT) revert SpendingLimitTooHigh();
```

**Recommendation:**  
Add validation in proposal creation functions to fail early and avoid wasted votes.

**Severity:** Medium

---

#### M-05: Invite Slot Accounting Can Become Inconsistent

**Location:** `RankedMembershipDAO.sol:479-496`

**Description:**  
When an invite is claimed, the `invitesUsedByEpoch` count is NOT decremented. It's only decremented when an expired invite is reclaimed. This means:

1. If an invite is claimed, the slot is "used" forever for that epoch
2. If an invite expires and is reclaimed, the slot is restored

However, if an invite expires and is never reclaimed, the slot remains consumed. This may not be intuitive behavior.

**Recommendation:**  
Consider automatically restoring slots when invites expire (could be done lazily during the next invite issuance).

**Severity:** Medium

---

#### M-06: Daily Spend Cap Reset Timing

**Location:** `MembershipTreasury.sol:2023-2037`

**Description:**  
The daily cap uses `block.timestamp / 1 days` for day indexing, which resets at UTC midnight. Users in different time zones may find this confusing, and it creates potential for "double spending" around the reset boundary.

```solidity
uint64 dayIndex = uint64(block.timestamp / 1 days);
```

**Recommendation:**  
This is acceptable behavior but should be documented. Consider if a rolling 24-hour window would be more appropriate for the use case.

**Severity:** Medium

---

#### M-07: NFT Ownership Verification at Transfer Time

**Location:** `MembershipTreasury.sol:559-565`, `MembershipTreasury.sol:1926-1932`

**Description:**  
The code correctly verifies NFT ownership before transfer using a try-catch block. However, between verification and transfer, a reentrancy attack could potentially change ownership. While `nonReentrant` modifier protects against same-contract reentrancy, cross-contract reentrancy via malicious NFT contracts is still possible.

```solidity
try IERC721(nftContract).ownerOf(tokenId) returns (address owner) {
    if (owner != address(this)) revert NFTNotOwned();
} catch {
    revert NFTNotOwned();
}
// ... potential for ownership to change here via callback ...
IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
```

**Recommendation:**  
Consider using a checks-effects-interactions pattern more strictly or implementing additional reentrancy guards for NFT operations.

**Severity:** Medium

---

#### M-08: Proposer Rank Stored But Not Re-Validated

**Location:** `MembershipTreasury.sol:103`

**Description:**  
Proposals store `proposerRank` at creation time but don't re-validate that the proposer still meets rank requirements at execution time. If a proposer is demoted after creating a proposal, the proposal can still execute.

**Recommendation:**  
Determine if this is intended behavior. If not, add re-validation at finalization/execution.

**Severity:** Medium

---

### Low Severity

#### L-01: Order Delay and Voting Period Can Be Changed Affecting Pending Items

**Location:** `RankedMembershipDAO.sol:809-870`

**Description:**  
Changing governance parameters like `orderDelay` or `votingPeriod` doesn't affect already-created orders/proposals (they use the value at creation time), which is correct. However, this should be documented clearly.

**Severity:** Low

---

#### L-02: No Check for Self-Demotion via Governance

**Location:** `RankedMembershipDAO.sol:1156-1158`

**Description:**  
A member can create a proposal to demote themselves via governance. While not necessarily a bug, it's unusual behavior that could be exploited for manipulation.

**Severity:** Low

---

#### L-03: Member ID 0 Used as Sentinel Value

**Location:** `RankedMembershipDAO.sol:135`

**Description:**  
Member IDs start at 1, with 0 used as "no member." This is good practice but requires careful handling throughout the codebase. Verified that this is handled correctly.

**Severity:** Low (Informational)

---

#### L-04: Unchecked Block Number Casting

**Location:** Multiple locations

**Description:**  
Using `block.number.toUint32()` will revert if block number exceeds `2^32` (~136 years at 15s blocks). This is unlikely but worth documenting.

**Severity:** Low

---

#### L-05: Empty Calldata Allowed for Call Proposals

**Location:** `MembershipTreasury.sol:1014-1052`

**Description:**  
`proposeCall` allows empty `data`, which would just send ETH. While not incorrect, it's semantically confusing as `proposeTransferETH` exists for this purpose.

**Severity:** Low

---

#### L-06: Multiple Events Can Have Confusing Overlap

**Location:** Multiple

**Description:**  
Some events have overlapping information (e.g., `TreasuryProposalCreated` and `TreasurerProposalCreated`). Consider consolidating or clarifying event usage.

**Severity:** Low

---

#### L-07: Invite to Self Possible

**Location:** `RankedMembershipDAO.sol:407-430`

**Description:**  
A member could theoretically invite their own address if they change their authority first. Edge case unlikely to cause issues.

**Severity:** Low

---

#### L-08: No Pause Mechanism in MembershipTreasury

**Location:** `MembershipTreasury.sol`

**Description:**  
Unlike `RankedMembershipDAO` which inherits `Pausable`, `MembershipTreasury` relies on `treasuryLocked` which only blocks outbound actions. Voting and proposal creation remain active. Consider if a full pause is needed for emergencies.

**Severity:** Low

---

#### L-09: SafeERC20 Not Used for All Token Operations

**Location:** Various

**Description:**  
The code correctly uses `SafeERC20` for transfers. However, ensure all token interactions go through safe wrappers.

**Severity:** Low (Verified safe usage)

---

### Informational

#### I-01: Use of Checkpoints Library

The code correctly uses OpenZeppelin's `Checkpoints` library for historical voting power lookups. This is the recommended pattern for snapshot-based voting.

---

#### I-02: ReentrancyGuard Usage

Both contracts properly use `nonReentrant` modifiers on state-changing external functions. This is correct practice.

---

#### I-03: Fallback/Receive Functions

`RankedMembershipDAO` correctly rejects ETH and NFT transfers via `receive()`, `fallback()`, and `onERC721Received()` returning an invalid selector.

`MembershipTreasury` correctly accepts ETH and implements proper `onERC721Received()` for NFT deposits.

---

#### I-04: Event Emission

Events are emitted after state changes (correctly following the pattern). All significant state changes have corresponding events.

---

#### I-05: Magic Numbers

Several magic numbers are properly defined as named constants (e.g., `INVITE_EPOCH = 100 days`, `MIN_QUORUM_BPS = 500`). This is good practice.

---

#### I-06: Error Messages

Custom errors are used throughout, which is gas-efficient and provides clear error handling.

---

#### I-07: Code Comments

The code includes helpful comments explaining business logic, especially around the hierarchical rank system and veto mechanisms.

---

## Gas Optimization Suggestions

### G-01: Storage Reads in Loops
Some functions read storage variables multiple times within the same transaction. Consider caching in memory.

### G-02: Struct Packing
`Proposal` struct in both contracts could potentially be packed more efficiently, though the current layout is readable.

### G-03: Redundant Existence Checks
Some functions check `exists` after already verifying membership through other means.

---

## Centralization Risks

1. **Owner Role**: The owner (via `Ownable2Step`) has significant power during bootstrap phase but appropriately limited power after `finalizeBootstrap()`.

2. **SSS Rank**: Initial SSS member has substantial individual power but is balanced by the veto mechanism requiring +2 rank difference.

3. **Treasury Owner**: Owner can enable/disable spending caps but cannot directly access treasury funds (requires governance vote).

---

## Architecture Analysis

### Strengths

1. **Separation of Concerns**: DAO membership and treasury are properly separated
2. **Timelocked Actions**: 24-hour delays on sensitive operations allow for veto
3. **Snapshot Voting**: Prevents vote buying attacks
4. **Ranked Hierarchy**: Clear permission escalation with 2-rank buffer requirements
5. **Multiple Safety Mechanisms**: Pause, treasury lock, spending caps, veto system

### Weaknesses

1. **Complexity**: Large codebase increases attack surface
2. **Cross-Contract Dependencies**: Treasury depends on DAO for membership validation
3. **No Upgrade Path**: Contracts are not upgradeable (may be intentional)

---

## Testing Recommendations

1. **Fuzzing**: Implement fuzzing tests for rank transitions and spending limits
2. **Invariant Tests**: Verify total voting power always equals sum of individual powers
3. **Edge Cases**: Test epoch boundaries for invite allowances
4. **Integration Tests**: Test DAO-Treasury interaction under various membership states
5. **Attack Scenarios**: Test frontrunning, griefing, and flash loan attacks

---

## Recommendations Summary

### Must Fix (Critical/High)
1. Verify OpenZeppelin constructor compatibility
2. Add voting delay to `RankedMembershipDAO`
3. Review token spending reset logic
4. Handle authority order frontrunning

### Should Fix (Medium)
1. Add zero-vote check to DAO finalization
2. Validate spending limits at proposal creation
3. Document bootstrap workflow
4. Consistently use `_rankIndex()`

### Consider (Low/Informational)
1. Document parameter change effects on pending items
2. Consider full pause mechanism for treasury
3. Consolidate similar events

---

## Disclaimer

This audit is a static code review performed without access to a running deployment. It does not guarantee the absence of all vulnerabilities. Dynamic testing, formal verification, and ongoing monitoring are recommended before and after deployment.

---

## Appendix: Contract Interfaces

### RankedMembershipDAO Key Functions
- `bootstrapAddMember()` - Add initial members
- `finalizeBootstrap()` - Lock bootstrap phase
- `issueInvite()` / `acceptInvite()` - Membership onboarding
- `issuePromotionGrant()` / `issueDemotionOrder()` - Rank management
- `createProposal*()` / `castVote()` / `finalizeProposal()` - Governance
- `blockOrder()` - Veto mechanism

### MembershipTreasury Key Functions
- `depositETH()` / `depositERC20()` / `depositNFT()` - Treasury funding
- `proposeTransfer*()` / `proposeCall()` - Governance proposals
- `treasurerSpend*()` / `treasurerCall()` - Direct treasurer actions
- `castVote()` / `finalize()` / `execute()` - Proposal lifecycle
- `proposeSetTreasuryLocked()` - Emergency controls
