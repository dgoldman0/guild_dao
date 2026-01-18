# Changelog

All notable changes to the Guild DAO project will be documented in this file.

## [Unreleased] - 2026-01-18

### Security Fixes

#### Critical

- **[C-01] Call Action Target Whitelist**: The `Call` action type for governance proposals now requires targets to be in the `approvedCallTargets` whitelist, matching the security model already used for treasurer calls. This prevents arbitrary code execution attacks via malicious governance proposals.

#### High

- **[H-01] Flash Loan Governance Attack Prevention**: Added a `VOTING_DELAY` constant (1 block) that prevents voting until at least 1 block after proposal creation. This mitigates same-block voting manipulation attacks where an attacker could create a proposal and vote in the same block.

- **[H-02] Treasurer Period Reset Bug Fix**: Fixed the spending limit period reset logic for both member-based and address-based treasurers. Previously, when the period expired during an ETH spend, only that asset's counter was properly reset. Now the `periodExpired` flag is computed once and used consistently for all asset types, ensuring token spending limits are properly reset when the period rolls over.

#### Medium

- **[M-01] Minimum Quorum Requirement**: Added a check in `finalize()` that requires at least 1 vote to be cast for a proposal to succeed. This prevents edge cases where the quorum calculation could truncate to 0 for very small voting power scenarios.

- **[M-04] Spending Limit Per Rank Cap**: Added `MAX_SPENDING_LIMIT_PER_RANK` constant (1,000 ether) and validation in `_executeAddMemberTreasurer` and `_executeUpdateMemberTreasurer` to prevent excessive spending limits. The `spendingLimitPerRankPower` multiplier is now capped to prevent SSS rank treasurers from having unbounded spending limits.

- **[M-07] Treasurer NFT Ownership Check**: Added ownership verification in `treasurerTransferNFT()` to check that the treasury actually owns the NFT before attempting transfer. This provides clearer error messaging with `NFTNotOwned()` instead of a generic ERC721 revert.

### New Features

#### Global Transfer Lock

Added a governance-controlled global transfer lock mechanism:

- New `transfersLocked` state variable (default: `false`)
- New `SetTransfersLocked` action type for proposals
- New `proposeSetTransfersLocked(bool locked)` function to create transfer lock proposals
- New `_executeSetTransfersLocked()` internal function
- New `TransfersLockedSet(bool locked)` event
- New `TransfersLocked()` error

When `transfersLocked` is `true`, the following operations are blocked:
- `treasurerSpendETH()` - treasurer ETH transfers
- `treasurerSpendERC20()` - treasurer ERC20 transfers
- `treasurerTransferNFT()` - treasurer NFT transfers
- `execute()` for `TransferETH` proposals
- `execute()` for `TransferERC20` proposals
- `execute()` for `TransferNFT` proposals

This allows the DAO to halt all outbound transfers in emergency situations via governance vote.

### New Constants

- `VOTING_DELAY = 1` - Number of blocks to wait after proposal creation before voting can begin
- `MAX_SPENDING_LIMIT_PER_RANK = 1_000 ether` - Maximum spending limit per rank power multiplier

### New Errors

- `TransfersLocked()` - Thrown when attempting transfers while global lock is active
- `VotingNotStarted()` - Thrown when attempting to vote before the voting delay has passed
- `InsufficientVotes()` - (Reserved for future use)

### Changed Behavior

1. **Call Proposals**: Now require both `callActionsEnabled = true` AND the target address to be in `approvedCallTargets`. Previously only the former was checked at execution time.

2. **Voting**: Voters must now wait at least `VOTING_DELAY` blocks after a proposal is created before casting votes.

3. **Quorum**: Proposals with zero votes will now always fail, regardless of quorum calculation.

4. **Treasurer Token Spending**: Period reset now properly handles cross-asset spending scenarios.

### Documentation

- Updated `AUDIT.md` with full security audit findings
- Created `CHANGELOG.md` to track changes

---

## Notes for Upgrading

If deploying an update to existing contracts:

1. **Breaking Changes**: The `Call` action type now requires whitelisted targets. Any pending `Call` proposals targeting non-whitelisted addresses will fail to execute.

2. **New State**: The `transfersLocked` boolean defaults to `false`, maintaining current behavior.

3. **Voting Delay**: Users should be aware that votes cannot be cast in the same block as proposal creation.
