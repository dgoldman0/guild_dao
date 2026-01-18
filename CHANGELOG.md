# Changelog

All notable changes to the Guild DAO contracts will be documented in this file.

## [Unreleased] - 2026-01-18

### Added - Governance Parameter Configuration

This release adds the ability for the DAO to vote on and change key governance parameters, with appropriate safeguards to prevent malicious or accidental misconfiguration.

#### RankedMembershipDAO.sol

**New Configurable Parameters (with safeguards):**

| Parameter | Default | Min | Max | Description |
|-----------|---------|-----|-----|-------------|
| `inviteExpiry` | 24 hours | 1 hour | 7 days | How long an invite remains valid |
| `orderDelay` | 24 hours | 1 hour | 7 days | Timelock for timelocked orders (promote/demote/authority) |
| `votingPeriod` | 7 days | 1 day | 30 days | Duration of the voting period for proposals |
| `quorumBps` | 2000 (20%) | 500 (5%) | 5000 (50%) | Minimum voting power required for quorum |
| `executionDelay` | 24 hours | 1 hour | 7 days | Timelock after proposal passes before execution |

**New Proposal Types:**
- `ChangeVotingPeriod` - Vote to change the voting period duration
- `ChangeQuorumBps` - Vote to change the quorum threshold
- `ChangeOrderDelay` - Vote to change the order delay timelock
- `ChangeInviteExpiry` - Vote to change invite expiration time
- `ChangeExecutionDelay` - Vote to change the execution delay for treasury proposals

**New Functions:**
- `createProposalChangeVotingPeriod(uint64 newValue)` - Create a proposal to change voting period
- `createProposalChangeQuorumBps(uint16 newValue)` - Create a proposal to change quorum BPS
- `createProposalChangeOrderDelay(uint64 newValue)` - Create a proposal to change order delay
- `createProposalChangeInviteExpiry(uint64 newValue)` - Create a proposal to change invite expiry
- `createProposalChangeExecutionDelay(uint64 newValue)` - Create a proposal to change execution delay

**New Events:**
- `ParameterProposalCreated(uint64 proposalId, ProposalType proposalType, uint32 proposerId, uint64 newValue, uint64 startTime, uint64 endTime, uint32 snapshotBlock)`
- `VotingPeriodChanged(uint64 oldValue, uint64 newValue, uint64 proposalId)`
- `QuorumBpsChanged(uint16 oldValue, uint16 newValue, uint64 proposalId)`
- `OrderDelayChanged(uint64 oldValue, uint64 newValue, uint64 proposalId)`
- `InviteExpiryChanged(uint64 oldValue, uint64 newValue, uint64 proposalId)`
- `ExecutionDelayChanged(uint64 oldValue, uint64 newValue, uint64 proposalId)`

**New Errors:**
- `InvalidParameterValue()` - When a parameter value is invalid
- `ParameterOutOfBounds()` - When a parameter value is outside allowed min/max bounds

**Proposal Struct Changes:**
- Added `newParameterValue` field to store the proposed parameter value

#### MembershipTreasury.sol

**Removed Hardcoded Constants:**
The following constants have been removed and replaced with dynamic calls to the DAO:
- `VOTING_PERIOD` → `dao.votingPeriod()`
- `QUORUM_BPS` → `dao.quorumBps()`
- `EXECUTION_DELAY` → `dao.executionDelay()`

**Updated Interface (IRankedMembershipDAO):**
Added getter functions for governance parameters:
- `votingPeriod() external view returns (uint64)`
- `quorumBps() external view returns (uint16)`
- `executionDelay() external view returns (uint64)`

**New View Functions:**
- `getVotingPeriod()` - Get current voting period from DAO
- `getQuorumBps()` - Get current quorum BPS from DAO
- `getExecutionDelay()` - Get current execution delay from DAO

### Security Considerations

**Safeguards Implemented:**

1. **Bounded Parameters**: All configurable parameters have minimum and maximum bounds to prevent extreme values:
   - Quorum cannot be set below 5% (prevents too-easy passing) or above 50% (prevents impossibility to reach quorum)
   - Time periods have reasonable bounds to prevent both instant execution and indefinite lockups

2. **Standard Governance Process**: All parameter changes must go through the standard governance process:
   - Proposal creation requires minimum rank F
   - Standard voting period applies (using current settings)
   - Quorum and majority requirements must be met
   - Changes take effect immediately upon successful finalization

3. **Double Validation**: Parameters are validated both at proposal creation time and at execution time

4. **Transparency**: All parameter changes emit events with old and new values for off-chain tracking

### Migration Notes

- Existing contracts will continue to work with the default values
- No action required for deployed instances; new parameters will use sensible defaults
- The Treasury contract now reads governance parameters from the DAO contract, ensuring unified governance settings
- Any changes to governance parameters in the DAO will automatically apply to Treasury proposals

### Breaking Changes

- `Proposal` struct has a new field (`newParameterValue`) - may affect off-chain indexers
- Previous constant values are now state variables with public getters
