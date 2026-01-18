# Change Order: Security Fixes for Guild DAO Contracts

Based on the security audit findings, this document outlines all changes that were implemented, ordered by severity.

**Status: ✅ IMPLEMENTED**

---

## Critical Severity Fixes

### C-01 & C-02: Implement SafeERC20 for All Token Operations ✅

**Files:** `MembershipTreasury.sol`

**Issue:** ERC20 `transfer()` and `transferFrom()` return values are not checked. Some tokens (like USDT) don't revert on failure.

**Implementation:**
1. ✅ Added SafeERC20 import from OpenZeppelin
2. ✅ Added `using SafeERC20 for IERC20;` declaration
3. ✅ Replaced `IERC20.transfer()` with `safeTransfer()` in `treasurerSpendERC20()` and `execute()`
4. ✅ Replaced `IERC20.transferFrom()` with `safeTransferFrom()` in `depositERC20()`

---

## High Severity Fixes

### H-03: Add Named Error for Bootstrap Revert ✅

**Files:** `RankedMembershipDAO.sol`

**Issue:** Unnamed `revert()` in `_bootstrapMember()` provides no error context.

**Implementation:**
1. ✅ Added custom error `BootstrapAlreadyFinalized()`
2. ✅ Replaced `revert()` with `revert BootstrapAlreadyFinalized()`

---

### H-02: Document Call Action Behavior ✅

**Issue:** `callActionsEnabled` can change between proposal creation and execution.

**Implementation:**
- ✅ Added documentation comment in `execute()` function explaining this is intentional safety behavior

---

## Medium Severity Fixes

### M-03: Use Explicit Rank Index Comparisons ✅

**Files:** `MembershipTreasury.sol`

**Issue:** Direct enum comparisons work but are less explicit.

**Implementation:**
- ✅ Added `_rankIndex()` helper function with documentation
- ✅ Updated rank comparisons in `_checkNFTAccess()` to use `_rankIndex()`
- ✅ Updated rank comparisons in `_getTreasurerInfo()` to use `_rankIndex()`

---

### M-04: Add Maximum Spending Limit Constant ✅

**Files:** `MembershipTreasury.sol`

**Issue:** No upper bound on treasurer spending limits.

**Implementation:**
1. ✅ Added `MAX_SPENDING_LIMIT = 10_000 ether` constant
2. ✅ Added `SpendingLimitTooHigh()` error
3. ✅ Added validation in `_executeAddMemberTreasurer()`
4. ✅ Added validation in `_executeAddAddressTreasurer()`
5. ✅ Added validation in `_executeUpdateMemberTreasurer()`
6. ✅ Added validation in `_executeUpdateAddressTreasurer()`

---

### M-07: Add Ownership Pre-Check for NFT Transfers ✅

**Files:** `MembershipTreasury.sol`

**Issue:** NFT transfer doesn't verify ownership before attempting transfer.

**Implementation:**
1. ✅ Added `NFTNotOwned()` error
2. ✅ Added ownership verification in `_executeTransferNFT()` using try/catch pattern

---

## Low Severity Fixes

### L-05: Add Zero Amount Validation ✅

**Files:** `MembershipTreasury.sol`

**Issue:** Zero-value transfers are allowed, wasting gas.

**Implementation:**
1. ✅ Added `ZeroAmount()` error
2. ✅ Added validation in `treasurerSpendETH()`
3. ✅ Added validation in `treasurerSpendERC20()`
4. ✅ Added validation in `depositERC20()`
5. ✅ Added validation in `proposeTransferETH()`
6. ✅ Added validation in `proposeTransferERC20()`

---

## Summary of Changes Implemented

| ID | Severity | File | Status |
|----|----------|------|--------|
| C-01/C-02 | Critical | MembershipTreasury.sol | ✅ Complete |
| H-03 | High | RankedMembershipDAO.sol | ✅ Complete |
| H-02 | High | MembershipTreasury.sol | ✅ Complete |
| M-03 | Medium | MembershipTreasury.sol | ✅ Complete |
| M-04 | Medium | MembershipTreasury.sol | ✅ Complete |
| M-07 | Medium | MembershipTreasury.sol | ✅ Complete |
| L-05 | Low | MembershipTreasury.sol | ✅ Complete |

---

## New Errors Added

```solidity
// MembershipTreasury.sol
error ZeroAmount();
error NFTNotOwned();
error SpendingLimitTooHigh();

// RankedMembershipDAO.sol
error BootstrapAlreadyFinalized();
```

## New Constants Added

```solidity
// MembershipTreasury.sol
uint256 public constant MAX_SPENDING_LIMIT = 10_000 ether;
```

## New Imports Added

```solidity
// MembershipTreasury.sol
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
```

---

*Implementation completed: January 18, 2026*
