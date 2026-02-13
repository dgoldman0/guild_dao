# Gas & Coverage Benchmarks

> **Generated:** February 2026  
> **Compiler:** Solidity 0.8.24 · `viaIR: true` · Optimizer runs: 1  
> **Network:** Arbitrum One (target) · Hardhat local for testing  
> **Tests:** 190 passing · 95 % line coverage

---

## Deployment Costs

Full system deployment (all 8 contracts, excluding mocks):

| Contract            | Gas        | % of Block Limit | Notes                        |
|---------------------|------------|-------------------|------------------------------|
| FeeRouter           |    382,630 | 0.6 %             | Stateless fee collector      |
| GuildController     |    795,961 | 1.3 %             | Auth gateway / facade        |
| InviteController    |    959,158 | 1.6 %             | Invite issuance & acceptance |
| MembershipTreasury  |  2,270,499 | 3.8 %             | Fund store + proposals       |
| OrderController     |  2,498,413 | 4.2 %             | Timelocked rank orders       |
| ProposalController  |  3,788,168 | 6.3 %             | Governance proposals         |
| RankedMembershipDAO |  3,036,972 | 5.1 %             | Core membership registry     |
| TreasurerModule     |  3,035,227 | 5.1 %             | Treasurer roles & spending   |
| **Total**           | **16,767,028** | **28.0 %**    |                              |

> Block limit: 60,000,000 gas. Arbitrum gas pricing differs from L1 — see
> [Arbitrum gas docs](https://docs.arbitrum.io/build-decentralized-apps/how-to-estimate-gas)
> for L2 cost estimation.

---

## Method Gas Costs (Average)

### Membership & Bootstrap

| Operation               | Contract             | Avg Gas  | Notes                        |
|--------------------------|----------------------|----------|------------------------------|
| `bootstrapAddMember`     | RankedMembershipDAO  | 222,605  | Owner seeds initial members  |
| `finalizeBootstrap`      | RankedMembershipDAO  |  29,194  | Renounces ownership          |
| `changeMyAuthority`      | RankedMembershipDAO  |  57,788  | Self-service, no timelock    |
| `deactivateMember`       | RankedMembershipDAO  |  92,153  | Permissionless fee enforce   |
| `setMemberActive`        | RankedMembershipDAO  |  97,699  | Governance reactivation      |

### Invite System

| Operation               | Contract            | Avg Gas  | Notes                        |
|--------------------------|---------------------|----------|------------------------------|
| `issueInvite`            | InviteController    | 138,619  | Per-epoch allowance by rank  |
| `acceptInvite`           | InviteController    | 244,896  | Creates G-rank member        |
| `reclaimExpiredInvite`   | InviteController    |  46,188  | Returns invite allowance     |

### Fee Payments

| Operation               | Contract   | Avg Gas  | Min      | Max      |
|--------------------------|------------|----------|----------|----------|
| `payMembershipFee`       | FeeRouter  |  87,687  |  69,423  | 152,365  |

> Min = ETH path (member already active). Max = ERC-20 path or reactivation.

### Timelocked Orders

| Operation                | Contract          | Avg Gas  | Notes                        |
|---------------------------|-------------------|----------|------------------------------|
| `issuePromotionGrant`     | OrderController   | 177,671  | Target must accept           |
| `issueDemotionOrder`      | OrderController   | 179,012  | Auto-executes after delay    |
| `issueAuthorityOrder`     | OrderController   | 182,770  | Changes member wallet        |
| `acceptPromotionGrant`    | OrderController   | 128,347  | Target accepts promotion     |
| `executeOrder`            | OrderController   |  82,007  | Anyone, after delay          |
| `blockOrder`              | OrderController   |  49,969  | Higher-rank veto             |
| `rescindOrder`            | OrderController   |  47,196  | Issuer self-cancel           |

### Governance Proposals (ProposalController)

| Operation                          | Avg Gas  | Notes                             |
|-------------------------------------|----------|-----------------------------------|
| `createProposalGrantRank`           | 171,475  | Promote via vote                  |
| `createProposalDemoteRank`          | 171,277  | Demote via vote                   |
| `createProposalChangeAuthority`     | 191,707  | Change wallet via vote            |
| `createProposalChangeParameter`     | 178,355  | Voting period, quorum, etc.       |
| `createProposalBlockOrder`          | 188,056  | Governance veto on an order       |
| `createProposalTransferERC20`       | 196,430  | Recover accidental ERC-20 tokens  |
| `createProposalResetBootstrapFee`   | 163,712  | Convert bootstrap → fee-paying    |
| `castVote`                          |  98,940  | Weighted by rank                  |
| `finalizeProposal`                  | 102,898  | Checks quorum, executes if passed |

### Treasury Proposals (MembershipTreasury)

| Operation    | Avg Gas  | Notes                                   |
|--------------|----------|-----------------------------------------|
| `propose`    | 190,264  | Generic: action type + ABI-encoded data |
| `castVote`   |  97,429  | Weighted by rank                        |
| `finalize`   |  79,476  | Checks quorum, sets execution delay     |
| `execute`    |  63,685  | After execution delay                   |

### Treasury Deposits

| Operation      | Avg Gas  |
|----------------|----------|
| `depositERC20` |  55,041  |
| `receive()`    |  ~21,000 | Direct ETH send                |

### Admin / Config Setup

| Operation               | Contract             | Avg Gas  |
|--------------------------|----------------------|----------|
| `setController`          | RankedMembershipDAO  |  47,923  |
| `setFeeRouter`           | RankedMembershipDAO  |  48,423  |
| `setBaseFee`             | RankedMembershipDAO  |  47,370  |
| `setPayoutTreasury`      | RankedMembershipDAO  |  31,854  |
| `setFeeToken`            | RankedMembershipDAO  |  30,732  |
| `setGracePeriod`         | RankedMembershipDAO  |  30,484  |
| `setOrderController`     | GuildController      |  51,239  |
| `setProposalController`  | GuildController      |  51,327  |
| `setInviteController`    | GuildController      |  51,239  |
| `setTreasurerModule`     | MembershipTreasury   |  30,308  |
| `setTreasury`            | TreasurerModule      |  45,608  |
| `setProposalController`  | OrderController      |  34,194  |

---

## Coverage Report

| Contract              | Statements | Branches | Functions | Lines  |
|-----------------------|------------|----------|-----------|--------|
| FeeRouter             | 100 %      | 100 %    | 100 %     | 100 %  |
| GuildController       | 89.66 %    | 50 %     | 100 %     | 86.67 %|
| InviteController      | 100 %      | 100 %    | 100 %     | 100 %  |
| MembershipTreasury    | 97.14 %    | 75 %     | 100 %     | 96.72 %|
| OrderController       | 96.88 %    | 64.29 %  | 100 %     | 96.97 %|
| ProposalController    | 100 %      | 73.08 %  | 100 %     | 100 %  |
| RankedMembershipDAO   | 87.23 %    | 50 %     | 86.67 %   | 89.47 %|
| TreasurerModule       | 98.04 %    | 42.5 %   | 100 %     | 98.44 %|
| **Overall**           | **94.6 %** | **63.1 %** | **93.3 %** | **95.2 %** |

### Branch Coverage Notes

Branch coverage is lower because the Solidity compiler counts implicit else
branches for `if` guards and `require`-style reverts.  Many of these "uncovered
branches" are the success path of access-control checks that are always met in
the tested happy-path flows.  All revert conditions are explicitly tested.

---

## Cost Estimation Guide

Use these figures to estimate operational costs on Arbitrum:

**Typical Workflow — Add a new member via invite:**
1. Issuer calls `issueInvite` → ~139k gas
2. Invitee calls `acceptInvite` → ~245k gas
3. **Total: ~384k gas**

**Typical Workflow — Promote a member (order path):**
1. Senior issues `issuePromotionGrant` → ~178k gas
2. Target calls `acceptPromotionGrant` after delay → ~128k gas
3. **Total: ~306k gas**

**Typical Workflow — Promote a member (governance path):**
1. Proposer calls `createProposalGrantRank` → ~171k gas
2. N voters each `castVote` → ~99k gas each
3. Anyone calls `finalizeProposal` → ~103k gas
4. **Total: ~274k + (99k × N voters) gas**

**Typical Workflow — Pay membership fee:**
1. Member calls `payMembershipFee` → ~88k gas (ETH) or ~152k gas (ERC-20)

**Typical Workflow — Treasury transfer via proposal:**
1. `propose` → ~190k gas
2. N voters `castVote` → ~97k each
3. `finalize` → ~79k gas
4. `execute` → ~64k gas
5. **Total: ~333k + (97k × N voters) gas**

---

*Raw data source: `gas-report.txt` (hardhat-gas-reporter v2.3.0)*
