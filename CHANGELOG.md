# Changelog

All notable changes to the Guild DAO contracts are documented in this file.

## [1.1.0] - 2026-01-18

### Security Fixes

This release addresses findings from the security audit conducted on 2026-01-18.

#### Critical

- **[C-01/C-02] SafeERC20 Implementation** (`MembershipTreasury.sol`)
  - Added `SafeERC20` import from OpenZeppelin
  - Added `using SafeERC20 for IERC20;` declaration
  - Changed `IERC20.transfer()` to `safeTransfer()` in:
    - `treasurerSpendERC20()` (line ~525)
    - `execute()` for `TransferERC20` action (line ~1658)
  - Changed `IERC20.transferFrom()` to `safeTransferFrom()` in:
    - `depositERC20()` (line ~453)
  - **Impact**: Prevents silent failures with non-standard ERC20 tokens (e.g., USDT)

#### High

- **[H-03] Named Error for Bootstrap Revert** (`RankedMembershipDAO.sol`)
  - Added `BootstrapAlreadyFinalized()` custom error
  - Replaced unnamed `revert()` with `revert BootstrapAlreadyFinalized()` in `_bootstrapMember()`
  - **Impact**: Improved error messaging and debugging

- **[H-02] Documented Call Action Behavior** (`MembershipTreasury.sol`)
  - Added documentation comment in `execute()` explaining that `callActionsEnabled` can change between proposal creation and execution
  - **Impact**: Clarifies intentional safety behavior for governance

#### Medium

- **[M-03] Explicit Rank Index Comparisons** (`MembershipTreasury.sol`)
  - Added `_rankIndex()` helper function for converting rank enum to numeric index
  - Updated rank comparisons in `_checkNFTAccess()` to use `_rankIndex(rank) >= _rankIndex(config.minRank)`
  - Updated rank comparisons in `_getTreasurerInfo()` to use `_rankIndex(rank) < _rankIndex(config.minRank)`
  - **Impact**: More explicit and maintainable rank comparisons

- **[M-04] Maximum Spending Limit** (`MembershipTreasury.sol`)
  - Added `MAX_SPENDING_LIMIT = 10_000 ether` constant
  - Added `SpendingLimitTooHigh()` custom error
  - Added validation in `_executeAddMemberTreasurer()`
  - Added validation in `_executeUpdateMemberTreasurer()`
  - Added validation in `_executeAddAddressTreasurer()`
  - Added validation in `_executeUpdateAddressTreasurer()`
  - **Impact**: Prevents governance from granting excessive spending power

- **[M-07] NFT Ownership Pre-Check** (`MembershipTreasury.sol`)
  - Added `NFTNotOwned()` custom error
  - Added ownership verification in `_executeTransferNFT()` before attempting transfer
  - **Impact**: Provides clear error when treasury doesn't own the NFT

#### Low

- **[L-05] Zero Amount Validation** (`MembershipTreasury.sol`)
  - Added `ZeroAmount()` custom error
  - Added zero amount checks to:
    - `depositERC20()`
    - `treasurerSpendETH()`
    - `treasurerSpendERC20()`
    - `proposeTransferETH()`
    - `proposeTransferERC20()`
  - **Impact**: Prevents wasteful zero-value transactions

### Added

- `SafeERC20` library usage for all ERC20 operations
- `BootstrapAlreadyFinalized` error in `RankedMembershipDAO.sol`
- `ZeroAmount` error in `MembershipTreasury.sol`
- `NFTNotOwned` error in `MembershipTreasury.sol`
- `SpendingLimitTooHigh` error in `MembershipTreasury.sol`
- `MAX_SPENDING_LIMIT` constant (10,000 ETH) in `MembershipTreasury.sol`
- `_rankIndex()` helper function in `MembershipTreasury.sol`

### Changed

- All ERC20 `transfer()` calls now use `safeTransfer()`
- All ERC20 `transferFrom()` calls now use `safeTransferFrom()`
- Rank comparisons now use explicit `_rankIndex()` function
- Treasurer spending limit validation now enforces maximum bounds
- NFT transfers now verify ownership before execution

### Documentation

- Added `AUDIT.md` - Full security audit report
- Added `CHANGE_ORDER.md` - Implementation plan for security fixes
- Added inline documentation comments for security-related changes

---

## [1.0.0] - Initial Release

### Features

#### RankedMembershipDAO.sol
- 10-tier rank system (G through SSS) with exponential voting power
- Invite system with epoch-based allowances and 24-hour expiry
- Timelocked orders for promotions, demotions, and authority changes
- Governance proposals with 7-day voting period and 20% quorum
- Snapshot-based voting using OpenZeppelin Checkpoints
- Bootstrap mechanism for initial member seeding

#### MembershipTreasury.sol
- ETH, ERC20, and NFT deposit and management
- Governance-controlled treasury proposals
- Treasurer system with member-based and address-based roles
- Rate-limited spending with configurable periods
- NFT access control per collection
- Approved call target whitelist for external interactions
- Optional daily spending caps
