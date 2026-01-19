# Changelog

All notable changes to the Guild DAO system are documented in this file.

## [Unreleased] - 2026-01-19

### Added

#### RankedMembershipDAO: Proper ERC-721 Rejection

**Added explicit ERC-721 transfer rejection via `IERC721Receiver` implementation:**

- **Added** `IERC721Receiver` interface import and implementation
- **Added** `onERC721Received()` function that reverts with `FundsNotAccepted` error
- **Added** `IERC20` and `SafeERC20` imports for ERC20 transfer functionality

This properly rejects NFT transfers via `safeTransferFrom()`. Note that `transferFrom()` cannot be blocked as it doesn't call `onERC721Received()`. Unsure of whether to add an NFT transfer by vote option as well or if it is becoming too much.

#### RankedMembershipDAO: TransferERC20 Proposal Type

**Added governance proposal type for recovering accidentally deposited ERC20 tokens:**

- **Added** `TransferERC20` to the `ProposalType` enum
- **Added** `erc20Token`, `erc20Amount`, and `erc20Recipient` fields to `Proposal` struct
- **Added** `createProposalTransferERC20(address token, uint256 amount, address recipient)` function
- **Added** `_executeTransferERC20Proposal()` internal function
- **Added** `_createProposalComplete()` internal function to support all proposal fields
- **Added** `TransferERC20ProposalCreated` event
- **Added** `ERC20Transferred` event

**Rationale:**

Unlike ETH (blocked by `receive()`) and NFTs via safeTransferFrom (blocked by `onERC721Received()`), ERC20 token transfers via `transfer()` cannot be blocked because they don't trigger any callback on the recipient. This proposal type allows the DAO to democratically vote to recover any accidentally deposited ERC20 tokens.

**Recovery Flow:**
1. F+ member creates proposal with `createProposalTransferERC20(token, amount, recipient)`
2. Standard voting period (7 days default)
3. If quorum + majority achieved, tokens are transferred via SafeERC20
4. `ERC20Transferred` event emitted

### Changed

#### RankedMembershipDAO: Updated Fund Rejection Documentation

**Clarified what can and cannot be blocked:**

| Asset Type | Can Block? | Mechanism |
|------------|------------|-----------|
| ETH | ✅ Yes | `receive()` reverts |
| NFTs via safeTransferFrom | ✅ Yes | `onERC721Received()` reverts |
| NFTs via transferFrom | ❌ No | No callback to intercept |
| ERC20 tokens | ❌ No | No callback to intercept |

---

## [Previous] - 2026-01-18

### Added

#### RankedMembershipDAO: Fund Rejection Protection

**Added automatic rejection of accidental fund transfers:**

- **Added** `receive()` function to reject direct ETH transfers
- **Added** `fallback()` function to reject token transfers and other calls
- **Added** `FundsNotAccepted` error for clear rejection messaging
- **Added** documentation in README.md explaining the fund rejection design

**Rationale:**

RankedMembershipDAO is exclusively for membership and governance operations. The separate `MembershipTreasury` contract handles all fund management. This design provides:
- **Safety** - Prevents accidental loss of funds due to misconfigured transfers
- **Clarity** - Clear separation of concerns between governance and treasury
- **Security** - Eliminates unintended state changes from token callbacks

Any ETH sent directly to the contract is rejected. Any ERC20 or NFT transfer attempts (via standard transfer functions) are rejected by the fallback handler.

### Changed

#### MembershipTreasury: Unified Governance-Controlled Lock System

**Replaced dual pause/lock system with single governance-controlled treasury lock:**

- **Removed** OpenZeppelin `Pausable` inheritance and owner-controlled `pause()`/`unpause()` functions
- **Renamed** `transfersLocked` → `treasuryLocked` to reflect comprehensive scope
- **Renamed** `SetTransfersLocked` → `SetTreasuryLocked` in `ActionType` enum
- **Renamed** `proposeSetTransfersLocked()` → `proposeSetTreasuryLocked()`
- **Renamed** `TransfersLocked` error → `TreasuryLocked`
- **Renamed** `TransfersLockedSet` event → `TreasuryLockedSet`

**Treasury lock now halts ALL outbound activity, not just transfers:**

When `treasuryLocked = true`:
- ❌ ETH transfers (governance proposals and treasurer direct spending)
- ❌ ERC20 transfers (governance proposals and treasurer direct spending)
- ❌ NFT transfers (governance proposals and treasurer direct spending)
- ❌ Call actions (governance proposals)
- ❌ Treasurer calls (`treasurerCall()`)

When `treasuryLocked = true`, the following remain active:
- ✅ Proposal creation (to enable unlock proposals)
- ✅ Voting on proposals
- ✅ Proposal finalization
- ✅ Deposits (ETH, ERC20, NFT)
- ✅ Executing `SetTreasuryLocked` proposals (to enable unlocking)

**Rationale:**

The previous system had two independent pause mechanisms:
1. Owner-controlled `Pausable` (centralized, bypasses governance)
2. Governance-controlled `transfersLocked` (democratic but only blocked transfers)

This created confusion and security concerns:
- Owner could unilaterally pause the entire contract
- Transfer lock didn't block `treasurerCall()` or governance Call proposals
- An attacker with treasurer access could still execute whitelisted calls even when "locked"

The new unified system:
- **Fully governance-controlled** - no owner override
- **Comprehensive** - blocks all outbound value movement
- **Recoverable** - voting/finalization/proposals remain active to enable unlock

### Removed

- `Pausable` import from OpenZeppelin
- `pause()` function (was owner-only)
- `unpause()` function (was owner-only)
- `whenNotPaused` modifier from all functions

### Added

- `treasuryLocked` check to `treasurerCall()` function
- `treasuryLocked` check to governance `Call` proposal execution
- Updated documentation comments throughout

### Security Implications

| Scenario | Before | After |
|----------|--------|-------|
| Owner pauses contract | All activity stopped | N/A (not possible) |
| Treasury locked via governance | Only transfers blocked | All outbound blocked |
| Treasurer calls when locked | ⚠️ Allowed | ✅ Blocked |
| Governance Call when locked | ⚠️ Allowed | ✅ Blocked |
| Deposits when locked | Allowed | Allowed |
| Voting when locked | Depended on pause state | Always allowed |
| Unlocking mechanism | Owner OR governance | Governance only |

---

### Added

#### Governance Override for Orders (Democratic Veto)
- Added new proposal type `BlockOrder` to the `ProposalType` enum
- Added `orderIdToBlock` field to the `Proposal` struct to store the target order ID
- Added `createProposalBlockOrder(uint64 orderId)` function allowing any F+ member to propose blocking a pending order via governance vote
- Added `_executeBlockOrderProposal()` internal function to handle BlockOrder proposal execution
- Added `_executeParameterProposal()` internal function for cleaner separation of parameter change execution
- Added `BlockOrderProposalCreated` event emitted when a BlockOrder proposal is created
- Added `OrderBlockedByGovernance` event emitted when an order is blocked via governance vote

This feature ensures that **even SSS-ranked orders can be blocked by direct democratic vote**, providing an additional layer of community protection beyond the existing rank-based veto system.

### Changed

#### Invite System - Rank-Gated Access
- Modified `inviteAllowanceOfRank()` function to restrict invitations to F-rank and above
- **Previous behavior:** All ranks could invite with allowance = `2^rankIndex` (G=1, F=2, E=4, ...)
- **New behavior:** Only F+ can invite with allowance = `2^(rankIndex - 1)` (G=0, F=1, E=2, D=4, ...)

| Rank | Old Allowance | New Allowance |
|------|---------------|---------------|
| G    | 1             | 0 (cannot invite) |
| F    | 2             | 1             |
| E    | 4             | 2             |
| D    | 8             | 4             |
| C    | 16            | 8             |
| B    | 32            | 16            |
| A    | 64            | 32            |
| S    | 128           | 64            |
| SS   | 256           | 128           |
| SSS  | 512           | 256           |

#### Internal Refactoring
- Refactored `_executeProposal()` to properly handle:
  - `BlockOrder` proposals (via `_executeBlockOrderProposal()`)
  - Parameter change proposals (via `_executeParameterProposal()`)
  - Member-related proposals (GrantRank, DemoteRank, ChangeAuthority)
- Updated `_createProposal()` and `_createProposalFull()` to delegate to new `_createProposalWithOrder()` function
- Added `_createProposalWithOrder()` internal function to support the new `orderIdToBlock` field

### Documentation

- Updated README.md:
  - Revised Key Features section to reflect F+ invite restriction and dual veto system
  - Updated "Invite Allowance" sections with new formula and table
  - Expanded "Veto Protection" section to document both rank-based and governance override mechanisms
  - Added `createProposalBlockOrder()` to Order Management Functions
  - Added "Block Order" to the list of proposal types

### Technical Details

#### New Proposal Flow for Blocking Orders
1. Any F+ member calls `createProposalBlockOrder(orderId)` with a pending order ID
2. Standard voting period applies (configurable, default 7 days)
3. If quorum is met and majority votes yes, the order is blocked
4. The target member is unlocked and can receive new orders
5. `OrderBlockedByGovernance(orderId, proposalId)` event is emitted

#### Security Considerations
- BlockOrder proposals validate that the order exists and hasn't already been blocked/executed
- The `blockedById` field is set to 0 to indicate governance (vs member) blocking
- Orders can still be blocked by rank-based veto during the 24-hour window
