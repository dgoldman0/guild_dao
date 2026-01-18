# Changelog

All notable changes to the Guild DAO system are documented in this file.

## [Unreleased] - 2026-01-18

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
