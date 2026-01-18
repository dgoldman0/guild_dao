# RankedMembershipDAO

A membership-controlled DAO smart contract with:
- 10 membership ranks (G → A → S → SS → SSS)
- Voting power that **doubles each rank**
- Invite-based onboarding with **24h expiry** and **100-day invite epochs**
- Timelocked member-management orders (promotion grants, demotions, authority recovery) with **24h delay + higher-rank veto**
- Snapshot-based governance proposals (grant rank, demote rank, change authority)

This README describes the **current contract version** (single-contract implementation) and its behaviors, guardrails, and known constraints.

---

## Contract summary

**Contract:** `RankedMembershipDAO`  
**Solidity:** `^0.8.24`  
**Libraries:** OpenZeppelin (Ownable2Step, Pausable, ReentrancyGuard, SafeCast, Checkpoints)

### Rank ladder

`G, F, E, D, C, B, A, S, SS, SSS`

Internally the ranks map to indices `0..9`. Higher index = higher power.

### Voting power

Voting weight is:

`votingPower(rank) = 2^rankIndex`

So:
- G = 1
- F = 2
- …
- SSS = 512

Voting uses **snapshot power** recorded via OpenZeppelin `Checkpoints`. A proposal snapshots at its creation block, and votes are counted using the member’s voting power at that snapshot block.

### Invite allowance

Invite allowance per epoch uses the same doubling model:

`inviteAllowance(rank) = 2^rankIndex`

Epoch length is fixed at **100 days**. Invite validity is fixed at **24 hours**.

---

## Deployment / bootstrap

On deployment:
- The deployer is bootstrapped as a member at rank **SSS**
- The deployer becomes `owner` (via `Ownable2Step`)

Bootstrap-only helpers exist for initial setup:
- `bootstrapAddMember(address authority, Rank rank)` (owner only)
- `finalizeBootstrap()` (owner only) → permanently ends bootstrap additions

Pausing:
- `pause()` / `unpause()` (owner only)

---

## Core concepts

### Member identity & authority

Each member has:
- a unique `memberId` (`uint32`)
- a `rank`
- an `authority` address

The **authority** address is the account that votes, proposes, issues invites, and issues orders. On join, the authority is the wallet that accepted the invite.

Members can:
- change their own authority immediately (`changeMyAuthority`)
- be assigned a new authority via a timelocked **AuthorityOrder** (wallet recovery workflow)
- be assigned a new authority via governance proposal **ChangeAuthority**

The contract enforces:
- one authority address maps to at most one `memberId` at any time

---

## Invites

### Flow

1. A member calls `issueInvite(to)`  
2. The invite reserves one invite “slot” in the issuer’s current **100-day epoch**
3. The invite can be claimed by `to` within **24 hours** using `acceptInvite(inviteId)`
4. If it expires, the issuer calls `reclaimExpiredInvite(inviteId)` to restore the reserved slot

### Accounting rules

- On `issueInvite`, the contract increments `invitesUsedByEpoch[issuerId][epoch]` immediately.
- On `acceptInvite`, the invite becomes claimed and mints a new member at rank `G`.
- On `reclaimExpiredInvite`, the invite becomes reclaimed and the reserved slot is returned (decrementing `invitesUsedByEpoch` for that epoch).

This structure makes “outstanding invites” naturally count against the epoch allowance, and expired invites can be reclaimed to restore capacity.

### Invite-related functions

- `issueInvite(address to) returns (uint64 inviteId)`
- `acceptInvite(uint64 inviteId) returns (uint32 newMemberId)`
- `reclaimExpiredInvite(uint64 inviteId)`

Views:
- `getInvite(uint64 inviteId)`
- `invitesUsedByEpoch(uint32 issuerId, uint64 epoch)`
- `inviteAllowanceOfRank(Rank r)` (pure)

Events:
- `InviteIssued(inviteId, issuerId, to, expiresAt, epoch)`
- `InviteClaimed(inviteId, newMemberId, authority)`
- `InviteReclaimed(inviteId, issuerId)`

---

## Timelocked Orders (member-to-member)

Orders are “local” actions issued by one member about another member (or their authority). Every order has:
- **24 hour delay**
- a **veto window** during that 24 hours

### Single outstanding order invariant

A target member can have **one** pending order at a time:
- `pendingOrderOfTarget[targetId]` holds the currently pending orderId
- Creating any order on a target requires that value to be `0`

Additionally, self authority change (`changeMyAuthority`) checks that the caller has no pending order as target.

### Veto rule

During the 24h window, an order can be blocked by a member whose rank is at least **two ranks above the issuer’s rank at creation**:

`blockerRank >= issuerRankAtCreation + 2`

Blocking clears the pending slot, allowing new actions on the target.

### Order types

#### 1) Promotion grant (acceptance required)
- Issuer can propose a new rank for a target.
- The proposed rank must be **at most issuerRank − 2**.
- The target must **accept after 24 hours**.

Functions:
- `issuePromotionGrant(uint32 targetId, Rank newRank) returns (uint64 orderId)`
- `acceptPromotionGrant(uint64 orderId)` (target authority only, after delay)
- `blockOrder(uint64 orderId)` (qualified veto, before delay)

#### 2) Demotion order (execution after delay)
- Issuer must be **at least 2 ranks above** the target.
- Reduces the target’s rank by **exactly one step**, bounded at `G`.
- Executes after 24 hours; any member can call `executeOrder`.

Functions:
- `issueDemotionOrder(uint32 targetId) returns (uint64 orderId)`
- `executeOrder(uint64 orderId)` (after delay)
- `blockOrder(uint64 orderId)` (qualified veto, before delay)

#### 3) Authority order (recovery / reassignment)
- Issuer must be **at least 2 ranks above** the target.
- Schedules a new authority address for the target.
- Executes after 24 hours; any member can call `executeOrder`.

Functions:
- `issueAuthorityOrder(uint32 targetId, address newAuthority) returns (uint64 orderId)`
- `executeOrder(uint64 orderId)` (after delay)
- `blockOrder(uint64 orderId)` (qualified veto, before delay)

Views:
- `getOrder(uint64 orderId)`
- `pendingOrderOfTarget(uint32 targetId)`

Events:
- `OrderCreated(orderId, orderType, issuerId, targetId, newRank, newAuthority, executeAfter)`
- `OrderBlocked(orderId, blockerId)`
- `OrderExecuted(orderId)`

---

## Governance proposals (global voting)

Governance proposals allow the whole membership to vote to:
1. **Grant rank to member** (promotion)
2. **Demote rank of member**
3. **Change authority** of member

### Eligibility & proposal limits

- Proposer must be at least rank **F**
- Each proposer has a cap on **active** proposals (created and not finalized)
- Limit increases with rank:
  - F: 1 active
  - E: 2 active
  - D: 3 active
  - C: 4 active
  - …
  - SSS: 9 active

Computed by `proposalLimitOfRank(Rank r)`.

### Snapshot voting

When a proposal is created, it records:
- `snapshotBlock = block.number`

Vote weight for each member is taken from:
- `votingPowerOfMemberAt(memberId, snapshotBlock)`

This means rank changes after proposal creation influence future proposals, and do not retroactively change the weight for an already-created proposal.

### Voting & finalization rules

- Voting window: `VOTING_PERIOD` (currently **7 days**)
- Passing requires:
  - **Quorum**: votes cast >= `QUORUM_BPS` (currently **20%**) of total snapshot power
  - **Majority**: `yesVotes > noVotes`
- Execution happens during `finalizeProposal` if it succeeds.

### Governance functions

Create:
- `createProposalGrantRank(uint32 targetId, Rank newRank) returns (uint64 proposalId)`
- `createProposalDemoteRank(uint32 targetId, Rank newRank) returns (uint64 proposalId)`
- `createProposalChangeAuthority(uint32 targetId, address newAuthority) returns (uint64 proposalId)`

Vote:
- `castVote(uint64 proposalId, bool support)`

Finalize:
- `finalizeProposal(uint64 proposalId)`

Views:
- `getProposal(uint64 proposalId)`
- `hasVoted(uint64 proposalId, uint32 voterId)`
- `activeProposalsOf(uint32 proposerId)`
- `totalVotingPowerAt(uint32 blockNumber)`
- `votingPowerOfMemberAt(uint32 memberId, uint32 blockNumber)`

Events:
- `ProposalCreated(proposalId, proposalType, proposerId, targetId, rankValue, newAuthority, startTime, endTime, snapshotBlock)`
- `VoteCast(proposalId, voterId, support, weight)`
- `ProposalFinalized(proposalId, succeeded, yesVotes, noVotes)`

### Interaction with pending orders

Governance execution checks:
- `pendingOrderOfTarget[targetId] == 0`

This keeps the “one outstanding order” rule coherent and avoids overlapping local orders with global execution for the same target.

---

## Security posture & standard measures

This version uses:
- **Checks-Effects-Interactions** style for state changes
- **ReentrancyGuard** on external state-changing functions (`nonReentrant`)
- **Pausable** to stop most actions during emergencies
- **Ownable2Step** to reduce owner transfer risk
- **Snapshot voting power** via OpenZeppelin **Checkpoints**, avoiding “vote weight changes mid-vote” issues
- **Custom errors** for cheaper, clearer failure conditions
- Authority uniqueness enforced via `memberIdByAuthority[newAuthority] == 0`

---

## Known constraints / current behavior

These are intentional in the current version and are common tuning points:

1. **Governance parameters are fixed constants**
   - `VOTING_PERIOD = 7 days`
   - `QUORUM_BPS = 2000`
   - `INVITE_EPOCH = 100 days`
   - `INVITE_EXPIRY = 24 hours`
   - `ORDER_DELAY = 24 hours`

2. **Proposal outcome uses simple majority + quorum**
   - No supermajority thresholds
   - No proposal cancellation mechanism

3. **No delegation**
   - Voting is tied to the member’s authority address

4. **Invite allowance uses doubling**
   - G gets 1 invite per 100 days, F gets 2, … SSS gets 512
   - If you want “tier 1 has 1 invite a year” exactly, adjust `INVITE_EPOCH` and/or the allowance schedule.

5. **Veto rule is based on issuer rank at creation**
   - The contract stores `issuerRankAtCreation` so the veto threshold stays stable during the veto window

6. **Order blocking window closes at executeAfter**
   - Blocking is allowed strictly before the delay elapses

7. **Bootstrap is owner-controlled**
   - Once `finalizeBootstrap()` is called, `bootstrapAddMember` becomes unusable

---

## Suggested testing checklist

- Membership:
  - Join via invite → memberId increments, rank=G, authority mapping set
  - Authority change clears old mapping and sets new mapping
- Invites:
  - Allowance matches rank doubling per epoch
  - Issue → used increments
  - Expire → accept fails; reclaim restores used
- Orders:
  - Only one pending per target
  - Promotion cap = issuerRank − 2
  - Promotion requires target acceptance after delay
  - Demotion reduces by 1 and clamps at G
  - Authority order enforces unused authority at execution time
  - Veto threshold uses issuerRankAtCreation + 2
- Governance:
  - Snapshot weight used even after rank changes
  - Quorum and majority logic behaves as expected
  - Proposer active proposal limit enforced by rank

---

## Quick reference: main entrypoints

### Member actions
- `issueInvite(to)`
- `acceptInvite(inviteId)`
- `reclaimExpiredInvite(inviteId)`
- `changeMyAuthority(newAuthority)`

### Orders
- `issuePromotionGrant(targetId, newRank)`
- `acceptPromotionGrant(orderId)`
- `issueDemotionOrder(targetId)`
- `issueAuthorityOrder(targetId, newAuthority)`
- `blockOrder(orderId)`
- `executeOrder(orderId)`

### Governance
- `createProposalGrantRank(targetId, newRank)`
- `createProposalDemoteRank(targetId, newRank)`
- `createProposalChangeAuthority(targetId, newAuthority)`
- `castVote(proposalId, support)`
- `finalizeProposal(proposalId)`

---

## Extending this version

Common next steps:
- Make governance parameters configurable via governance (with timelock)
- Add proposal cancellation rules (e.g., proposer-only cancel before votes)
- Add delegation (memberId delegates to another memberId)
- Add offchain vote signatures (EIP-712) for gasless voting
- Add multi-sig or onchain timelock for owner privileges during bootstrap

---

## License

MIT
