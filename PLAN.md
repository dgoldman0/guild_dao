# Guild DAO — Development Plan

_Last updated: 2026-02-09_

Current architecture: 8 contracts.

| Contract | Role | Status |
|---|---|---|
| RankedMembershipDAO | Core membership + params | Deployed |
| GuildController | Sole DAO controller (facade) | Deployed |
| OrderController | Timelocked rank/authority orders | Deployed |
| ProposalController | Governance proposals | Deployed |
| InviteController | Invite-based member onboarding | Deployed |
| MembershipTreasury | Treasury proposals + execution | Deployed |
| TreasurerModule | Treasury action logic | Deployed |
| FeeRouter | Fee payment routing | Deployed |

---

## Stage 1 — Order Limits & Rescind ✅

**Commit:** `bb94ccf` — `feat: order limits per rank & rescindOrder`

- Added `orderLimitOfRank()` to DAO (E=1, D=2, C=4… doubling pattern).
- Added `activeOrdersOf` tracking in OrderController.
- Enforced per-rank concurrent order cap on all 3 order types.
- Decremented active count on execute, block, rescind, and governance-block.
- Added `rescindOrder()` — issuer cancels their own pending order.
- Consolidated 5 parameter-change proposal functions into `createProposalChangeParameter()`.
- 13 new tests covering limits and rescind.

---

## Stage 2 — Comprehensive Test Coverage ✅

**Commit:** `1a51e31` — `test: comprehensive test coverage (Stage 2)`

77 tests total covering:
- **DAO:** bootstrap (4), setController (4), changeMyAuthority (4), pause (2), fund rejection (1), voting power (3), rank helpers (3)
- **Invites:** issue, accept, double-accept, expiry, reclaim, G-rank blocked, existing member (8)
- **Orders:** all 3 types, delay, blocking, single-target (7)
- **Order Limits:** SSS multi, E-rank cap, slot freed by execute/block (4)
- **Rescind:** happy path, non-issuer, executed, blocked, slot free, outsider (6)
- **Governance Proposals:** GrantRank, DemoteRank, ChangeAuthority, ChangeVotingPeriod, BlockOrder, TransferERC20, vote-after-end, double-vote, early-finalize, quorum, tie, decrement (12)
- **Treasury:** deposits, TRANSFER_ETH/ERC20 lifecycle, settings, revert paths, locked (12)
- **Security:** onlyController, onlyModule, onlyTreasury (3)

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
