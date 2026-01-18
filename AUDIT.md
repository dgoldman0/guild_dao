# Security Audit Report: Guild DAO

**Audit Date:** January 18, 2026  
**Contracts Audited:**
- `RankedMembershipDAO.sol` (1093 lines)
- `MembershipTreasury.sol` (2097 lines)

**Solidity Version:** ^0.8.24  
**Dependencies:** OpenZeppelin Contracts v5+

---

## Executive Summary

This audit reviews the Guild DAO system, consisting of a ranked membership DAO with timelocked governance and a companion treasury contract with spending controls. The contracts implement a hierarchical membership system with 10 ranks (G through SSS), snapshot-based voting, invite mechanics, and treasury management features.

**Overall Assessment:** The codebase demonstrates solid security practices with proper use of OpenZeppelin security primitives (ReentrancyGuard, Pausable, Ownable2Step, SafeERC20). However, several issues of varying severity were identified.

### Summary of Findings

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 7 |
| Low | 8 |
| Informational | 6 |

---

## Critical Findings

### [C-01] Arbitrary Code Execution via `Call` Action Type

**Location:** `MembershipTreasury.sol:1670-1674`

**Description:** When `callActionsEnabled` is true, the `execute()` function allows arbitrary external calls with any calldata and ETH value. This enables:
- Arbitrary token approvals to malicious addresses
- Calls to self-destruct contracts
- Interaction with malicious contracts that could drain the treasury
- Reentrancy through external calls (mitigated by ReentrancyGuard but still risky)

**Code:**
```solidity
} else if (p.action.actionType == ActionType.Call) {
    if (!callActionsEnabled) revert ActionDisabled();
    (bool ok,) = p.action.target.call{value: p.action.value}(p.action.data);
    if (!ok) revert ExecutionFailed();
}
```

**Impact:** Complete loss of treasury funds if malicious proposals pass governance.

**Recommendation:** 
1. Implement a target whitelist for call actions (similar to `approvedCallTargets` for treasurers)
2. Consider removing generic `Call` action type entirely
3. Add calldata validation or restrict to specific function signatures
4. Require higher quorum for dangerous actions

---

## High Severity Findings

### [H-01] Flash Loan Governance Attack Vector

**Location:** `RankedMembershipDAO.sol:917-937`, `MembershipTreasury.sol:1597-1612`

**Description:** The snapshot is taken at `block.number` when a proposal is created. Since voting begins immediately at `startTime = block.timestamp`, and the snapshot block is the current block, an attacker could:
1. Acquire significant voting power (via rapid rank promotions if possible, or coordination)
2. Create a proposal in the same block
3. Vote immediately with inflated power

While the rank system provides some protection, if governance parameters are changed to allow same-block voting, this becomes exploitable.

**Code:**
```solidity
p.snapshotBlock = block.number.toUint32();
p.startTime = uint64(block.timestamp);
```

**Impact:** Potential manipulation of governance votes.

**Recommendation:** Introduce a voting delay after proposal creation (e.g., 1 block minimum) before votes can be cast.

### [H-02] Treasurer Period Reset Logic Vulnerability

**Location:** `MembershipTreasury.sol:691-729`

**Description:** When checking spending limits in `_checkAndRecordTreasurerSpending`, the period reset logic only resets the specific token's spent amount when the period expires:

```solidity
if (currentTime >= periodStart + periodDuration) {
    spending.periodStart = currentTime;
    spending.spentInPeriod = 0;
    // Reset token spending too
    memberTreasurerTokenSpent[memberId][token] = 0;
    spentInPeriod = 0;
}
```

However, if a treasurer spends ETH first (resetting the period), then spends tokens, the token spending from the previous period isn't properly cleared if the ETH spending already reset `periodStart`. This can lead to **underflow of intended limits** in edge cases.

**Impact:** Potential for treasurers to exceed intended spending limits.

**Recommendation:** Reset all token spending counters when the period resets, or track each token's period independently.

### [H-03] Member Removal Not Handled in Treasury

**Location:** `MembershipTreasury.sol` (entire treasurer system)

**Description:** If a DAO member is somehow removed or their authority changes, the `MembershipTreasury` doesn't automatically revoke their treasurer privileges. The member-based treasurer check only validates the current authority:

```solidity
memberId = dao.memberIdByAuthority(spender);
if (memberId != 0 && memberTreasurers[memberId].active) {
    // ...
}
```

If the member's authority is changed to a new address, the OLD authority loses access, but the NEW authority gains it without explicit approval.

**Impact:** Unauthorized access to treasurer functions after authority changes.

**Recommendation:** Add explicit handling for authority changes, requiring re-approval of treasurer status when authority changes.

---

## Medium Severity Findings

### [M-01] Quorum Calculation Uses Basis Points Truncation

**Location:** `RankedMembershipDAO.sol:1021-1023`, `MembershipTreasury.sol:1634-1635`

**Description:** The quorum calculation uses integer division:
```solidity
uint256 required = (uint256(totalAtSnap) * quorumBps) / 10_000;
```

For small total voting power values, this truncates down, potentially making the quorum requirement 0.

**Example:** If `totalAtSnap = 3` and `quorumBps = 2000` (20%), then:
`required = (3 * 2000) / 10000 = 6000 / 10000 = 0`

**Impact:** Proposals could pass with no votes in extreme edge cases.

**Recommendation:** Add a minimum quorum requirement (e.g., at least 1 vote required).

### [M-02] Proposal Can Be Created Targeting Non-Existent Members

**Location:** `MembershipTreasury.sol:1254-1273` (proposeGrantMemberNFTAccess)

**Description:** While there's a check for `memberExists` at proposal creation time, the member could be removed (if such functionality exists) before execution. The execution doesn't re-validate member existence for all action types.

**Impact:** Proposal execution could fail or operate on stale data.

**Recommendation:** Re-validate all assumptions at execution time, not just at proposal creation.

### [M-03] Owner Can Pause Contract Indefinitely

**Location:** `RankedMembershipDAO.sol:324-330`, `MembershipTreasury.sol:442-443`

**Description:** The contract owner has unilateral power to pause the contract indefinitely, blocking all governance actions. While this is a safety mechanism, it concentrates power dangerously.

**Impact:** Single point of failure; owner can halt all DAO operations.

**Recommendation:** 
1. Implement time-limited pauses
2. Add governance override for pause after a timeout
3. Consider transferring ownership to the DAO itself after bootstrap

### [M-04] No Upper Bound on `spendingLimitPerRankPower`

**Location:** `MembershipTreasury.sol:1725-1739`

**Description:** While `baseSpendingLimit` is capped at `MAX_SPENDING_LIMIT`, the `spendingLimitPerRankPower` multiplier has no cap. For high-rank members, this could result in extremely large spending limits:

```solidity
limit = config.baseSpendingLimit + (config.spendingLimitPerRankPower * rankPower);
```

SSS rank has voting power of 512 (2^9). If `spendingLimitPerRankPower` is set to a large value, limits could exceed intended bounds.

**Impact:** Potential for excessive spending limits.

**Recommendation:** Add validation for `spendingLimitPerRankPower` to ensure total possible limit stays reasonable.

### [M-05] Missing Event Emission for Some Proposal Types

**Location:** `MembershipTreasury.sol:1273-1294`

**Description:** The `proposeGrantMemberNFTAccess` function emits no event (uses internal helper which emits `TreasurerProposalCreated`), but `proposeTransferNFT` emits `TreasuryProposalCreated` directly. This inconsistency makes off-chain monitoring difficult.

**Impact:** Inconsistent event logging; monitoring difficulties.

**Recommendation:** Ensure consistent event emission across all proposal creation functions.

### [M-06] Invite Epoch Boundary Attack

**Location:** `RankedMembershipDAO.sol:383-401`

**Description:** The invite system uses a 100-day epoch for rate limiting:
```solidity
uint64 epoch = _currentEpoch();
```

An attacker could wait until just before an epoch boundary, use all invite slots, wait for the epoch to change, then immediately use all new slots, effectively doubling their invite rate over a short period.

**Impact:** Temporary burst of invites beyond intended rate.

**Recommendation:** Consider a sliding window approach instead of fixed epochs.

### [M-07] NFT Transfer Without Ownership Verification in Treasurer Functions

**Location:** `MembershipTreasury.sol:538-548`

**Description:** The `treasurerTransferNFT` function attempts to transfer an NFT without first checking if the treasury owns it:

```solidity
function treasurerTransferNFT(address nftContract, address to, uint256 tokenId) external whenNotPaused nonReentrant {
    // ... access checks ...
    IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
}
```

While this will revert if the treasury doesn't own the NFT, it provides poor error messaging.

**Note:** The governance proposal path (`_executeTransferNFT`) correctly checks ownership first.

**Impact:** Poor UX with unclear revert messages.

**Recommendation:** Add ownership check before attempting transfer.

---

## Low Severity Findings

### [L-01] Missing Input Validation for Array Bounds

**Location:** `RankedMembershipDAO.sol:74-80`

**Description:** The `Rank` enum has 10 values (0-9), and casting to `uint8` is safe, but there's no explicit validation that rank comparisons don't overflow.

**Impact:** Minimal; enum casting is safe in Solidity 0.8+.

### [L-02] Centralization Risk in Bootstrap Phase

**Location:** `RankedMembershipDAO.sol:334-338`

**Description:** The owner can add arbitrary members at any rank during bootstrap, including multiple SSS members. This could be used to stack governance before finalization.

**Impact:** Trust assumption on deployer during bootstrap.

**Recommendation:** Add transparency about bootstrap members or limit bootstrap additions.

### [L-03] No Grace Period for Demoted Treasurers

**Location:** `MembershipTreasury.sol:618-665`

**Description:** When a member's rank drops below the treasurer's `minRank`, they immediately lose treasurer access. This could disrupt ongoing operations.

**Impact:** Sudden access revocation without warning.

**Recommendation:** Consider a grace period or notification mechanism.

### [L-04] `proposalLimitOfRank` Inconsistency

**Location:** `MembershipTreasury.sol:831-835`

**Description:** The treasury contract calls `IRankedMembershipDAO.proposalLimitOfRank(r)` through the interface, but this is a `pure` function in the DAO. The call pattern works but is unusual for pure functions accessed via interface.

**Impact:** None functionally; code clarity issue.

### [L-05] Order Blocking Doesn't Validate Blocker Still Exists

**Location:** `RankedMembershipDAO.sol:682-700`

**Description:** When blocking an order, the function validates the blocker's rank but doesn't explicitly check if the blocker member still exists.

**Impact:** Minimal; the authority check implies existence.

### [L-06] No Maximum on Active Proposals Per Member

**Location:** `RankedMembershipDAO.sol:849-852`

**Description:** While there's a rank-based limit on active proposals, a high-rank member (SSS) could have up to 9 active proposals simultaneously, potentially fragmenting voter attention.

**Impact:** Governance attention fragmentation.

### [L-07] Timestamp Dependence

**Location:** Multiple locations using `block.timestamp`

**Description:** The contracts rely on `block.timestamp` for timing. Miners can manipulate timestamps within certain bounds (~15 seconds).

**Impact:** Minimal; typical for governance contracts.

### [L-08] Missing Zero-Value Checks in Constructor

**Location:** `MembershipTreasury.sol:424`

**Description:** The treasury constructor validates `daoAddress != address(0)`, which is good, but the DAO constructor has no similar validation for initial state.

**Impact:** Deployment failure would be obvious but not graceful.

---

## Informational Findings

### [I-01] Unused Error Definitions

**Location:** `MembershipTreasury.sol`

**Description:** Some errors may be defined but never used or used in specific edge cases only. Consider reviewing error coverage.

### [I-02] Large Contract Size

**Location:** `MembershipTreasury.sol` (2097 lines)

**Description:** The treasury contract is large and handles many responsibilities. Consider splitting into smaller modules if deployment costs or readability become issues.

**Recommendation:** Consider using a proxy pattern or splitting functionality.

### [I-03] Magic Numbers

**Location:** Various

**Description:** Some constants like `10_000` (basis points denominator), `2` (rank difference for actions) are used as literals. Consider named constants for clarity.

### [I-04] Function Visibility Optimization

**Description:** Some `internal` functions could potentially be `private` if not intended for inheritance. Gas savings would be minimal but readability improves.

### [I-05] Missing NatSpec Documentation

**Location:** Various internal functions

**Description:** While public functions have documentation, some internal functions lack NatSpec comments explaining their purpose.

### [I-06] Potential Gas Optimization in Loops

**Description:** The contracts don't have explicit loops, but the checkpoint system from OpenZeppelin has its own gas characteristics. Monitor for large member counts.

---

## Architecture Review

### Strengths

1. **Proper Use of Security Primitives:** OpenZeppelin's `ReentrancyGuard`, `Pausable`, `Ownable2Step`, and `SafeERC20` are correctly implemented.

2. **Snapshot-Based Voting:** Using checkpoints for voting power prevents vote manipulation during active proposals.

3. **Timelocked Orders:** The 24-hour delay on promotions/demotions with veto capability provides safety.

4. **Execution Delay:** Treasury proposals have an execution delay after passing, allowing detection of malicious proposals.

5. **Rank-Based Access Control:** The hierarchical permission system with rank differences (e.g., issuer must be 2+ ranks above target) is well-designed.

6. **Spending Limits:** Per-period spending limits for treasurers provide ongoing protection.

### Concerns

1. **Single DAO Dependency:** The treasury completely depends on the DAO contract. If the DAO is compromised, the treasury is compromised.

2. **Upgrade Path:** No upgrade mechanism exists. Any bugs require new deployments and migrations.

3. **Recovery Mechanisms:** No emergency recovery mechanism for stuck funds (by design, but worth noting).

4. **Cross-Contract Consistency:** Authority changes in DAO aren't synced to treasury treasurer status.

---

## Recommendations Summary

### Critical Priority
- [ ] Implement target whitelist for `Call` action type or remove it
- [ ] Add re-validation of conditions at proposal execution time

### High Priority
- [ ] Fix treasurer period reset logic for token spending
- [ ] Add voting delay after proposal creation
- [ ] Sync treasurer status with DAO authority changes

### Medium Priority
- [ ] Add minimum quorum requirement (at least 1 vote)
- [ ] Cap `spendingLimitPerRankPower` based on max rank power
- [ ] Standardize event emission across proposal types
- [ ] Add ownership check in `treasurerTransferNFT`

### Low Priority
- [ ] Consider sliding window for invite rate limiting
- [ ] Add grace period for treasurer demotion
- [ ] Review and consolidate error definitions
- [ ] Add comprehensive NatSpec documentation

---

## Test Coverage Recommendations

The following scenarios should be covered by unit and integration tests:

1. **Governance Edge Cases:**
   - Proposal with exactly quorum votes
   - Proposal ending with tie votes
   - Proposals created at epoch boundaries
   
2. **Treasurer Spending:**
   - Period rollover with partial spending
   - Mixed ETH and token spending in same period
   - Rank demotion during active treasurer period
   
3. **Authority Changes:**
   - Member changes authority while being a treasurer
   - Authority change during active proposal voting
   
4. **NFT Operations:**
   - Transfer of NFT no longer owned by treasury
   - Transfer at period boundary
   
5. **Attack Vectors:**
   - Flash governance attack simulation
   - Reentrancy attempts through Call action
   - Epoch boundary invite burst

---

## Conclusion

The Guild DAO codebase demonstrates thoughtful security design with proper use of established patterns. The main areas of concern are:

1. The arbitrary `Call` action type which provides a significant attack surface
2. State synchronization between DAO and Treasury contracts
3. Edge cases in spending limit period tracking

With the recommended fixes, the contracts would be suitable for production deployment. A follow-up audit after implementing critical and high priority fixes is recommended.

---

*This audit was performed to the best of my ability using static analysis. It does not guarantee the absence of vulnerabilities. A professional audit by a specialized security firm is recommended before mainnet deployment.*
