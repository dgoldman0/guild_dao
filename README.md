# Guild DAO System

> A hierarchical ranked-membership DAO with timelocked governance, treasury
> management, and invite-based onboarding — targeting Arbitrum One.

**190 tests · 95 % line coverage · 8 contracts · Solidity 0.8.24**

---

## Table of Contents

1. [Architecture](#architecture)
2. [Rank System](#rank-system)
3. [Contracts](#contracts)
4. [Governance Flows](#governance-flows)
5. [Treasury System](#treasury-system)
6. [Fee System](#fee-system)
7. [Quick Start](#quick-start)
8. [Deployment](#deployment)
9. [Testing & Security](#testing--security)
10. [Frontend](#frontend)

---

## Architecture

```
                         ┌───────────────────────┐
                         │  RankedMembershipDAO  │  Core registry:
                         │  (Ownable, Pausable)  │  members, ranks,
                         │                       │  voting power,
                         │                       │  config params
                         └──────────┬────────────┘
                                    │ sole controller
                         ┌──────────▼────────────┐
                         │    GuildController     │  Auth gateway
                         │       (facade)        │  (forwards calls
                         │                       │   after auth check)
                         └──┬───────┬─────────┬──┘
                            │       │         │
              ┌─────────────▼┐  ┌───▼──────┐  ┌▼──────────────┐
              │ OrderCtrl    │  │ Proposal │  │ InviteCtrl    │
              │              │  │  Ctrl    │  │               │
              │ Timelocked   │  │ Snapshot │  │ Per-epoch     │
              │  promote /   │  │  voting  │  │  invite       │
              │  demote /    │  │  + exec  │  │  allowance    │
              │  authority   │  │          │  │               │
              └──────────────┘  └──────────┘  └───────────────┘

         ┌────────────────────┐       ┌──────────────────┐
         │ MembershipTreasury │◄─────►│  TreasurerModule │
         │   (fund store)     │       │  (spending roles) │
         │   ETH/ERC20/NFT   │       │  member + address │
         │   proposals        │       │  based treasurers │
         └────────────────────┘       └──────────────────┘

         ┌──────────────┐
         │  FeeRouter   │  Collects membership fees →
         │              │  forwards to payoutTreasury →
         │              │  calls DAO.recordFeePayment()
         └──────────────┘
```

**Data flow:**
- External callers interact with OrderController, ProposalController,
  InviteController, MembershipTreasury, and FeeRouter.
- OrderController / ProposalController / InviteController call through
  **GuildController** (the DAO's sole `controller`).
- GuildController verifies the caller is an authorized sub-controller
  and forwards the call to RankedMembershipDAO.
- MembershipTreasury holds all treasury funds. TreasurerModule calls back
  into the treasury via `moduleTransfer*` / `moduleCall` entry-points.

---

## Rank System

10-tier hierarchy with exponential scaling:

| Rank | Index | Voting Power | Invite Allowance | Order Limit | Proposal Limit |
|------|-------|:------------:|:----------------:|:-----------:|:--------------:|
| G    | 0     | 1            | 0                | 0           | 0              |
| F    | 1     | 2            | 1                | 0           | 1              |
| E    | 2     | 4            | 2                | 1           | 2              |
| D    | 3     | 8            | 4                | 2           | 3              |
| C    | 4     | 16           | 8                | 4           | 4              |
| B    | 5     | 32           | 16               | 8           | 5              |
| A    | 6     | 64           | 32               | 16          | 6              |
| S    | 7     | 128          | 64               | 32          | 7              |
| SS   | 8     | 256          | 128              | 64          | 8              |
| SSS  | 9     | 512          | 256              | 128         | 9              |

- **Voting power** = `2^rankIndex`
- **Invite allowance** = `2^(rankIndex - 1)` for F+, 0 for G
- **Order limit** = `2^(rankIndex - 2)` for E+, 0 for G/F
- **Proposal limit** = `1 + (rankIndex - 1)` for F+, 0 for G
- Ranks are per 100-day **epoch** (invite allowance resets each epoch)

---

## Contracts

### RankedMembershipDAO

Core membership registry. Holds member data (id, rank, authority, joinedAt),
voting power snapshots (OpenZeppelin `Checkpoints.Trace224`), rank math
helpers, configurable governance parameters, bootstrap controls, fee
configuration, and fund rejection (reverts for ETH, NFTs via
`safeTransferFrom`, and fallback).

**Key state:**
- `membersById` / `memberIdByAuthority` — member lookup by ID or wallet
- `memberActive` / `feePaidUntil` — fee-based activity status
- `controller` — sole GuildController address
- `feeRouter` — authorized fee payment recorder

**Configurable parameters (with bounds):**

| Parameter       | Default  | Min       | Max       |
|-----------------|----------|-----------|-----------|
| `votingPeriod`  | 7 days   | 1 day     | 30 days   |
| `quorumBps`     | 2000     | 500 (5%)  | 5000 (50%)|
| `orderDelay`    | 24 hours | 1 hour    | 7 days    |
| `inviteExpiry`  | 24 hours | 1 hour    | 7 days    |
| `executionDelay`| 24 hours | 1 hour    | 7 days    |

**Bootstrap flow:**
1. Deployer is auto-added as SSS member
2. `bootstrapAddMember(authority, rank)` seeds initial members (fee-exempt forever)
3. `finalizeBootstrap()` renounces ownership — DAO becomes fully decentralized

### GuildController

Authorization facade between the 3 sub-controllers and the DAO. Verifies
`msg.sender` against registered controller addresses before forwarding:

| Caller               | Allowed Operations                                    |
|----------------------|-------------------------------------------------------|
| OrderController      | `setRank`, `setAuthority`                             |
| ProposalController   | `setRank`, `setAuthority`, parameter setters, `transferERC20`, `resetBootstrapFee`, `setMemberActive` |
| InviteController     | `addMember`                                           |

Sub-controller addresses are set by the DAO owner (during bootstrap) or by the
ProposalController (post-bootstrap governance).

### OrderController

Timelocked hierarchical order system. Higher-ranked members issue orders that
execute after a delay, giving the community time to intervene:

| Order Type        | Requirement            | Execution                |
|-------------------|------------------------|--------------------------|
| `PromoteGrant`    | Issuer ≥ target + 2    | Target accepts after delay |
| `DemoteOrder`     | Issuer ≥ target + 2    | Anyone executes after delay |
| `AuthorityOrder`  | Issuer ≥ target + 2    | Anyone executes after delay |

**Veto system:**
- **Rank-based:** Any member with rank ≥ issuer + 2 can `blockOrder` during delay
- **Governance:** ProposalController calls `blockOrderByGovernance` via a `BlockOrder` proposal
- **Self-cancel:** Issuer calls `rescindOrder`

Each issuer has a concurrent order limit based on rank (`orderLimitOfRank`).
Only one outstanding order per target member at a time.

### ProposalController

Snapshot-based democratic governance. Any F+ member creates proposals; all
members vote with rank-weighted power; finalization checks quorum and executes
immediately if passed.

**Proposal types:**

| Type                        | Payload               | Effect                        |
|-----------------------------|-----------------------|-------------------------------|
| `GrantRank`                 | targetId, newRank     | Promote via vote              |
| `DemoteRank`                | targetId, newRank     | Demote via vote               |
| `ChangeAuthority`           | targetId, newAuthority| Change member wallet via vote |
| `ChangeVotingPeriod`        | newValue              | Update voting period          |
| `ChangeQuorumBps`           | newValue              | Update quorum threshold       |
| `ChangeOrderDelay`          | newValue              | Update timelocked order delay |
| `ChangeInviteExpiry`        | newValue              | Update invite expiry duration |
| `ChangeExecutionDelay`      | newValue              | Update treasury exec delay    |
| `BlockOrder`                | orderId               | Governance veto on order      |
| `TransferERC20`             | token, amount, to     | Recover tokens from DAO       |
| `ResetBootstrapFee`         | targetMemberId        | Convert bootstrap → fee-paying|

**Lifecycle:** Create → Vote (during `votingPeriod`) → `finalizeProposal` (after end) → executes immediately if quorum met & majority yes.

### InviteController

Invite-based G-rank member onboarding with per-epoch allowance:

1. F+ member calls `issueInvite(address to)` — deducts 1 from epoch allowance
2. Invitee calls `acceptInvite(inviteId)` within expiry — creates G-rank member
3. If expired + unclaimed, issuer calls `reclaimExpiredInvite` to recover allowance

### MembershipTreasury

General-purpose fund store for ETH, ERC-20, and NFT assets. Features a
governance proposal system (separate from ProposalController) with an execution
delay for added safety.

**Deposits:** `receive()` (ETH), `depositERC20`, `depositNFT`, `onERC721Received`

**Proposal lifecycle:** `propose(actionType, data)` → `castVote` → `finalize` (after voting period) → `execute` (after execution delay)

**Action types** (defined in `ActionTypes` library):

| ID | Action                      | Executor            |
|----|------------------------------|---------------------|
| 0  | `TRANSFER_ETH`              | Treasury (direct)   |
| 1  | `TRANSFER_ERC20`            | Treasury (direct)   |
| 2  | `CALL`                      | Treasury (direct)   |
| 3–15 | Treasurer/NFT management | TreasurerModule     |
| 16–20 | Settings (locks, calls) | Treasury (direct)   |

**Safety features:**
- `treasuryLocked` — governance-controlled global lock (blocks all outbound)
- `capsEnabled` + `dailyCap` — per-asset daily spending limits
- `callActionsEnabled` + `approvedCallTargets` — whitelist for arbitrary calls

### TreasurerModule

Manages two types of designated spenders with rate-limited access:

**Member-based treasurers:** Linked to a DAO member ID; spending limit scales
with rank power (`baseLimit + limitPerRank × votingPower`). Enforces min rank.

**Address-based treasurers:** Linked to an EOA/contract; fixed spending limit
per period.

**Direct spending functions:**
- `treasurerSpendETH(to, amount)`
- `treasurerSpendERC20(token, to, amount)`
- `treasurerTransferNFT(nftContract, to, tokenId)`
- `treasurerCall(target, value, data)`

All spending checks: treasury not locked, caller is active treasurer, within
period spending limit, within token-specific limit if configured.

NFT access is granted per-collection with transfer-per-period limits.

### FeeRouter

Stateless fee collector. Reads fee config from the DAO, collects ETH or ERC-20,
forwards to `payoutTreasury`, and calls `dao.recordFeePayment()` to extend the
member's paid-until epoch.

**Fee formula:** `feeOfRank(rank) = baseFee × 2^rankIndex`

---

## Governance Flows

### How to promote a member (two paths)

**Order path** (fast, hierarchical):
```
Senior (E+) → issuePromotionGrant(targetId, newRank)
                     ↓ 24h delay (vetoable)
Target      → acceptPromotionGrant(orderId)
```

**Governance path** (democratic, any rank up to SSS):
```
F+ member   → createProposalGrantRank(targetId, newRank)
All members → castVote(proposalId, true/false) [7 day default]
Anyone      → finalizeProposal(proposalId)  → executes if passed
```

### How to change a governance parameter

```
F+ member   → createProposalChangeParameter(ChangeVotingPeriod, 3 days)
All members → castVote(proposalId, true/false)
Anyone      → finalizeProposal(proposalId)  → calls DAO setter if passed
```

### How to transfer treasury funds

```
F+ member   → propose(TRANSFER_ETH, abi.encode(to, amount))
All members → castVote(proposalId, true/false)
Anyone      → finalize(proposalId)           → sets execution delay
Anyone      → execute(proposalId)            → transfers funds after delay
```

### How to block an order via governance

```
F+ member   → createProposalBlockOrder(orderId)
All members → castVote(proposalId, true/false)
Anyone      → finalizeProposal(proposalId)  → blocks the order if passed
```

---

## Treasury System

### Proposal-based transfers

Members create proposals to transfer ETH, ERC-20, or NFTs. The proposal
goes through voting → finalize → execute (with execution delay between
finalize and execute for safety).

### Treasurer direct spending

For operational efficiency, designated treasurers can spend directly without
proposals, up to their configured limits:

```
Governance → propose ADD_MEMBER_TREASURER(memberId, baseLim, limPerRank, period, minRank)
           → vote → finalize → execute
           → TreasurerModule stores config

Treasurer  → treasurerSpendETH(to, amount)  // checked against period limit
```

### Safety layers

1. **Treasury Lock** — `SET_TREASURY_LOCKED` blocks all outbound (voting/proposals remain active for unlocking)
2. **Daily Caps** — per-asset caps on proposal-based spending
3. **Call Whitelist** — `CALL` actions require `callActionsEnabled` + approved targets
4. **Treasurer Calls** — `treasurerCall` requires `treasurerCallsEnabled` + approved targets
5. **Period Limits** — each treasurer has a time-windowed spending cap
6. **NFT Limits** — per-collection transfer-per-period caps

---

## Fee System

Optional membership fees enforce engagement:

1. **Owner configures** `baseFee`, `feeToken`, `gracePeriod`, `payoutTreasury` during bootstrap
2. **Members pay** via `FeeRouter.payMembershipFee(memberId)` — supports ETH or ERC-20
3. **Fee amount** = `baseFee × 2^rankIndex` — scales with rank
4. **First epoch free** for invited members; bootstrap members are forever fee-exempt
5. **Grace period** — configurable buffer after expiry before deactivation
6. **Anyone can enforce** via `deactivateMember(memberId)` after expiry + grace
7. **Reactivation** — paying the fee automatically reactivates and restores voting power
8. **Bootstrap reset** — governance can convert fee-exempt bootstrap members via `ResetBootstrapFee` proposal

---

## Quick Start

### Prerequisites

- Node.js ≥ 18
- npm

### Install & Test

```bash
git clone <repo-url>
cd guild_dao
npm install
npx hardhat test          # 190 tests
```

### Run Coverage

```bash
npm run coverage          # HTML report at coverage/index.html
```

### Run Gas Report

```bash
npm run test:gas          # Output at gas-report.txt
```

### Run Security Audit

```bash
npm run audit             # Slither + Solhint + Coverage
npm run lint              # Solhint only
npm run slither           # Slither only
```

---

## Deployment

### Local (Hardhat)

```bash
npx hardhat node                              # Terminal 1
npx hardhat run scripts/deploy-local.js --network localhost  # Terminal 2
```

### Arbitrum (production)

```bash
# Set PRIVATE_KEY and ARBISCAN_API_KEY in .env
npx hardhat run scripts/deploy.js --network arbitrum
```

**Deployment sequence:**
1. Deploy `RankedMembershipDAO`
2. Deploy `GuildController(dao)`
3. Deploy `OrderController(dao, guildCtrl)`
4. Deploy `ProposalController(dao, orderCtrl, guildCtrl)`
5. Deploy `InviteController(dao, guildCtrl)`
6. Deploy `MembershipTreasury(dao)`
7. Deploy `TreasurerModule(dao)`
8. Deploy `FeeRouter(dao)`
9. Wire: `dao.setController(guildCtrl)`, `guildCtrl.set*Controller(...)`,
   `orderCtrl.setProposalController(proposals)`, `treasury.setTreasurerModule(module)`,
   `module.setTreasury(treasury)`, `dao.setFeeRouter(feeRouter)`,
   `dao.setPayoutTreasury(treasury)`, `dao.setBaseFee(...)`, etc.
10. Bootstrap members → `dao.finalizeBootstrap()` (renounces ownership)

**Total deployment gas:** ~16.8M gas (see [GAS-AND-COVERAGE.md](GAS-AND-COVERAGE.md))

---

## Testing & Security

| Tool              | Command            | Purpose                        |
|-------------------|--------------------|--------------------------------|
| Hardhat Tests     | `npm test`         | 190 unit/integration tests     |
| Foundry Fuzz      | `npm run test:fuzz`| 44 property-based fuzz tests   |
| All Tests         | `npm run test:all` | Both suites                    |
| Solhint           | `npm run lint`     | Solidity linting               |
| Slither           | `npm run slither`  | Static analysis                |
| Coverage          | `npm run coverage` | Line/branch coverage (95%)     |
| Gas Reporter      | `npm run test:gas` | Gas cost profiling             |

**Documentation:**
- [GAS-AND-COVERAGE.md](GAS-AND-COVERAGE.md) — Gas costs per operation + coverage table
- [SECURITY.md](SECURITY.md) — Security testing guide
- [AUDIT-RESULTS.md](AUDIT-RESULTS.md) — Detailed audit findings & resolutions
- [CHANGELOG.md](CHANGELOG.md) — Development history

---

## Frontend

React + Vite + Tailwind dashboard at `frontend/`:

```bash
cd frontend
npm install
node node_modules/vite/bin/vite.js --host   # Dev server on port 5173
```

Features: member dashboard, invite management, order display, proposal
creation/voting, treasury overview, fee payment interface.

---

## Contract Interfaces

### IRankedMembershipDAO

Used by MembershipTreasury and FeeRouter to read DAO state:

```solidity
function membersById(uint32 id) external view returns (bool, uint32, Rank, address, uint64);
function memberIdByAuthority(address a) external view returns (uint32);
function votingPowerOfMemberAt(uint32 memberId, uint32 blockNumber) external view returns (uint224);
function totalVotingPowerAt(uint32 blockNumber) external view returns (uint224);
function votingPeriod() external view returns (uint64);
function quorumBps() external view returns (uint16);
function executionDelay() external view returns (uint64);
function feeOfRank(Rank r) external view returns (uint256);
function feePaidUntil(uint32 memberId) external view returns (uint64);
function recordFeePayment(uint32 memberId) external;
```

### IMembershipTreasury

Used by TreasurerModule to move funds:

```solidity
function moduleTransferETH(address to, uint256 amount) external;
function moduleTransferERC20(address token, address to, uint256 amount) external;
function moduleTransferNFT(address nftContract, address to, uint256 tokenId) external;
function moduleCall(address target, uint256 value, bytes calldata data) external returns (bytes memory);
function treasuryLocked() external view returns (bool);
function treasurerCallsEnabled() external view returns (bool);
function approvedCallTargets(address target) external view returns (bool);
```

### ITreasurerModule

Used by MembershipTreasury to forward treasurer actions:

```solidity
function executeTreasurerAction(uint8 actionType, bytes calldata data) external;
```

---

## License

MIT
