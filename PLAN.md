# Guild DAO — Development Plan

_Last updated: 2026-02-09_

Current architecture: 4 contracts + 1 library + 2 interfaces.

| Contract | Bytecode | Status |
|---|---|---|
| RankedMembershipDAO | ✅ under 24 KB | Deployed |
| GovernanceController | ✅ under 24 KB | Deployed |
| MembershipTreasury | ✅ under 24 KB | Deployed |
| TreasurerModule | ✅ under 24 KB | Deployed |

---

## Stage 1 — Order Limits & Rescind

**Goal:** Add per-rank concurrent order limits and the ability for issuers to rescind pending orders early.

### 1a. Order Limits
- Track `activeOrdersOf[memberId]` in GovernanceController.
- Enforce a per-rank cap (same doubling pattern as invites: `1 << (rankIndex - 1)`, F=1, E=2, D=4 …).
- Increment on order creation, decrement on execute / block / rescind / expiry.

### 1b. Rescind Orders
- Add `rescindOrder(uint64 orderId)` — issuer can cancel their own unexecuted, unblocked order.
- Emits `OrderRescinded(orderId)`, decrements `activeOrdersOf`.

### 1c. Tests
- Order limit enforcement (at cap → revert, after execute → slot freed).
- Rescind happy path, rescind by non-issuer reverts, rescind already-executed reverts.
- blockOrder still works and frees slot.

---

## Stage 2 — Comprehensive Test Coverage (existing features)

**Goal:** Harden the existing codebase with thorough tests before adding new features.

### 2a. RankedMembershipDAO Tests
- Bootstrap: add multiple members, finalize, verify owner is renounced.
- Post-bootstrap: bootstrapAddMember reverts.
- setController by owner, setController by controller (migration), revert for random caller.
- changeMyAuthority: success, duplicate-address revert, zero-address revert.
- Pause/unpause: changeMyAuthority blocked while paused.
- Fund rejection: ETH send reverts, ERC721 safeTransferFrom reverts.
- Voting power snapshots: promote → check historical power at old block.

### 2b. GovernanceController Tests
- Invite: full epoch allowance tracking, expiry, reclaim, double-accept revert.
- Orders: promotion grant, demotion, authority change. Time-delay enforcement. Block by higher-rank.
- Proposals: each ProposalType (GrantRank, DemoteRank, ChangeAuthority, all 5 parameter types, BlockOrder, TransferERC20).
- Full vote cycle: propose → castVote → finalizeProposal → verify state mutation.
- Edge cases: vote after end, double vote, finalize too early, quorum not met.

### 2c. MembershipTreasury Tests
- propose() for each ActionType constant (0–20).
- Vote + finalize + execute for TRANSFER_ETH (fund treasury, propose, vote, wait, finalize, execute, verify recipient balance).
- Vote + finalize + execute for TRANSFER_ERC20 (same pattern with MockERC20).
- Settings proposals: SET_TREASURY_LOCKED, SET_CALL_ACTIONS_ENABLED.
- Spend cap enforcement.
- Revert paths: execute before delay, execute failed proposal, double execute.

### 2d. TreasurerModule Tests
- Full proposal lifecycle: propose ADD_MEMBER_TREASURER → vote → finalize → execute → verify config.
- treasurerSpendETH within limit, over limit.
- treasurerSpendERC20 within limit.
- Period reset: spend → advance time past period → spend again.
- treasurerTransferNFT with mock NFT.
- treasuryLocked blocks spending.

---

## Stage 3 — Governance Proposal E2E Tests

**Goal:** End-to-end integration tests exercising full proposal flows across all four contracts.

- DAO parameter change: propose ChangeVotingPeriod → vote → finalize → verify dao.votingPeriod() changed.
- Rank change via governance: propose GrantRank → vote → finalize → verify member rank changed.
- ERC20 recovery from DAO: propose TransferERC20 → vote → finalize → verify tokens moved.
- Treasury ETH transfer: deposit → propose → vote → finalize → execute → verify ETH moved.
- Module action via treasury: propose ADD_MEMBER_TREASURER → vote → finalize → execute → verify TreasurerModule state.
- Cross-contract security: outsider can't call onlyController, onlyModule, onlyTreasury.

---

## Stage 4 — Membership Fees _(future)_

**Goal:** Introduce periodic membership fees that activate/deactivate voting power.

- Fee schedule per rank (higher rank = higher fee), tied to EPOCH.
- Active/inactive flag on Member struct; inactive members have 0 voting power.
- Fee payment function on Treasury (or new FeeModule).
- Both DAO and Treasury must respect active/inactive status.
- Grace period before deactivation.

---

## Stage 5 — Configurable Rank Parameters _(future)_

**Goal:** Allow governance to adjust rank parameters without redeploying.

- Move invite allowance, proposal limit, and voting power multiplier from pure functions to configurable storage.
- Add proposal types for changing rank parameters.
- Requires careful migration path from hardcoded values.

---

## Stage 6 — Treasury DAO Reassignment _(future)_

**Goal:** Allow the Treasury to change which DAO contract it reports to, via governance vote.

- Remove `immutable` from `dao` in MembershipTreasury and TreasurerModule.
- Add a new ActionType for SET_DAO.
- Requires supermajority or elevated quorum.

---

## Notes

- Each stage gets its own commit (or series of commits for large stages).
- Stages 4–6 are design sketches; details will be filled in when we get there.
- The old `IDEAS.md` and `ideas.txt` are superseded by this document.
