# 🏛️ Guild DAO System

> **A sophisticated, hierarchical DAO framework combining ranked membership governance with powerful treasury management.**

A comprehensive membership-controlled DAO with ranked governance and treasury management. Guild DAO enables communities to organize through a tiered membership system with proportional voting power, secure onboarding via invites, and a flexible treasury controlled by democratic voting and designated treasurers.

## 🎯 Key Features

- **10-Tier Ranking System** - Exponential voting power scaling (G through SSS, 1× → 512× power)
- **Invite-Based Onboarding** - Decentralized membership growth (F+ only) with 24-hour expiry and 100-day epochs
- **Timelocked Orders** - 24-hour execution delays with dual veto rights (rank-based + governance override)
- **Snapshot Voting** - Block-based voting power snapshots preventing flash loan attacks
- **Multi-Type Treasury** - Support for ETH, ERC20, NFTs, and arbitrary contract calls
- **Flexible Treasurers** - Both member-based (rank-dependent) and address-based (fixed limits) spending authorities
- **Emergency Lockdown** - Governance-controlled global transfer lock for crisis scenarios
- **Comprehensive Audit Trail** - Full security audit documentation with resolved findings

## System Architecture

The Guild DAO consists of two complementary contracts:

1. **RankedMembershipDAO** - Membership management, ranks, invites, timelocked orders, and governance voting
2. **MembershipTreasury** - Treasury fund management with proposal voting, treasurer systems, and asset controls

---

# 🎖️ RankedMembershipDAO Contract

The core membership and governance engine, implementing a hierarchical member system with exponential voting power, secure invite distribution, and democratic decision-making.

## Key Specifications

### Rank Hierarchy

The Guild DAO uses a 10-tier rank system where each rank represents a position in the hierarchy:

```
G (Initiate)
 ↓
F (Associate) 
 ↓
E (Member)
 ↓
D (Senior Member)
 ↓
C (Advisor)
 ↓
B (Officer)
 ↓
A (Executive)
 ↓
S (Director)
 ↓
SS (Senior Director)
 ↓
SSS (Founder) ⭐
```

Internally, ranks map to indices 0–9, where higher indices grant exponentially more power.

### Voting Power (Exponential Scaling)

Each rank doubles the voting power of the previous rank:

| Rank | Index | Voting Power |
|------|-------|--------------|
| G | 0 | 1 |
| F | 1 | 2 |
| E | 2 | 4 |
| D | 3 | 8 |
| C | 4 | 16 |
| B | 5 | 32 |
| A | 6 | 64 |
| S | 7 | 128 |
| SS | 8 | 256 |
| SSS | 9 | 512 |

**Formula:** `votingPower(rank) = 2^rankIndex`

This exponential model ensures that higher-ranked members have meaningful influence while maintaining a reasonable distribution curve. A single SSS member has 512× the voting power of a G member but never unilateral control in a diverse DAO.

### Invite Allowance (Rank-Gated Exponential Model)

Only members ranked **F or higher** can issue invites. The allowance doubles with each rank:

| Rank | Invites per Epoch |
|------|------------------|
| G | 0 (cannot invite) |
| F | 1 |
| E | 2 |
| D | 4 |
| C | 8 |
| B | 16 |
| A | 32 |
| S | 64 |
| SS | 128 |
| SSS | 256 |

**Formula:** `invitesPerEpoch(rank) = 2^(rankIndex - 1)` for F+, 0 for G

A 100-day epoch resets the invite counter. Invites have a fixed 24-hour expiry, allowing rejected invites to be reclaimed and reissued.

### Proposal Capacity

Proposal limits scale linearly by rank (starting at F):

| Rank | Max Active Proposals |
|------|-----|
| G | 0 (cannot propose) |
| F | 1 |
| E | 2 |
| D | 3 |
| ... | ... |
| SSS | 9 |

---

### Voting Snapshots & Flash Loan Protection

Voting uses **block-based voting snapshots** via OpenZeppelin `Checkpoints`:

- When a proposal is created, the voting power of all members is **locked at that block**
- Votes are counted using each member's voting power **at the snapshot block**
- This prevents **flash loan attacks** where an attacker could acquire voting power mid-voting through a single transaction
- Voting delay (1 block minimum) further mitigates same-block voting manipulation

**Example:** If you receive a rank promotion at block 100, you can vote starting at block 102+ (after a 1-block delay), using your new voting power.

### Invite Allowance

Only F or higher can invite. Formula: `inviteAllowance(rank) = 2^(rankIndex - 1)` for F+, 0 for G.

| Rank | Invites per Epoch |
|------|------------------|
| G | 0 |
| F | 1 |
| E | 2 |
| D | 4 |
| ... | ... |
| SSS | 256 |

Epoch length is fixed at **100 days**. Invite validity is fixed at **24 hours**.

---

## Deployment & Bootstrapping

On deployment:
- The deployer is bootstrapped as a **SSS-ranked member** (highest authority)
- The deployer becomes `owner` (via `Ownable2Step` for secure 2-step ownership transfer)

The owner can initialize the DAO with bootstrap functions:
- `bootstrapAddMember(address authority, Rank rank)` - Add initial members during setup
- `finalizeBootstrap()` - Permanently disable bootstrap additions and lock the system

Emergency control:
- `pause()` / `unpause()` - Freeze or unfreeze all operations

---

## Core Concepts

### Member Identity & Authority

Each member has three key attributes:

| Attribute | Type | Role |
|-----------|------|------|
| **memberId** | uint32 | Unique identifier within the DAO |
| **rank** | Rank enum | Determines voting power, invite allowance, and proposal limits |
| **authority** | address | The wallet that controls voting, invites, and orders |

The **authority address** is the wallet that performs all actions on behalf of the member:
- Voting on proposals
- Creating new proposals and orders
- Issuing and accepting invites
- Recovering their own authority (via timelocked order)

**Key Invariant:** One authority address = one memberId (1-to-1 mapping)

### Authority Management

Members can manage their authority through three methods:

1. **Immediate Self-Update** - Change your own authority anytime
   ```solidity
   changeMyAuthority(address newAuthority)
   ```

2. **Timelocked Recovery** - Regain control if your authority address is compromised
   ```solidity
   issueAuthorityOrder(targetMemberId, newAuthority)
   // After 24 hours + veto window, execute the order
   ```

3. **Governance Proposal** - DAO can reassign authority for flagged members
   ```solidity
   proposeChangeAuthority(targetMemberId, newAuthority)
   // Requires vote and 24-hour execution delay
   ```

---

## 📬 Invite System

The invite system enables decentralized membership growth while preventing spam through epoch-based rate limiting.

### Invite Flow

**Step 1: Issue Invite**
```
Member A (rank E, 4 invites/epoch) calls issueInvite(0xBob)
↓
Invite #42 created with 24-hour expiry
Invite slot reserved from A's epoch quota
```

**Step 2a: Accept Invite (Success Path)**
```
Bob calls acceptInvite(42) within 24 hours
↓
New Member (rank G) created for Bob
Bob becomes the authority for their account
```

**Step 2b: Reclaim Invite (Timeout Path)**
```
24 hours pass without Bob accepting
↓
Member A calls reclaimExpiredInvite(42)
↓
Invite slot returned to A's epoch quota
```

### Invite Accounting

| Event | Effect |
|-------|--------|
| `issueInvite()` | Increments `invitesUsedByEpoch[issuerId][epoch]` |
| `acceptInvite()` | Creates new member at rank G; invite becomes claimed |
| `reclaimExpiredInvite()` | Decrements used counter; invite becomes reclaimed |

### Core Invite Functions

```solidity
// Issue an invite to a specific address
issueInvite(address to) returns (uint64 inviteId)

// Accept an invite and join the DAO (creates new member at rank G)
acceptInvite(uint64 inviteId) returns (uint32 newMemberId)

// Reclaim a slot if invite expires (unused after 24 hours)
reclaimExpiredInvite(uint64 inviteId)
```

---

## ⏱️ Timelocked Orders (Member-to-Member Management)

Orders provide a decentralized way for higher-ranked members to manage other members, with built-in safety mechanisms: 24-hour delays and rank-based veto rights.

### Order Lifecycle

Every order follows the same flow:

```
1. Issue Order (T=0)
   ↓
2. Veto Window (24 hours)
   Higher-ranked members can block
   ↓
3. Execution Window (after T+24h)
   Original issuer executes the order
```

### Single Outstanding Order Invariant

Each member can have **at most one pending order at a time**. This prevents order spam and ensures clear, sequential rank/authority management.

### Veto Protection

Orders can be blocked through two mechanisms:

#### 1. Rank-Based Veto

During the 24-hour window, higher-ranked members can veto an order if:

$$\text{blockerRank} \geq \text{issuerRank} + 2$$

**Example Veto Scenarios:**
- A B-ranked member issues an order → Only S, SS, or SSS can veto it
- An E-ranked member issues an order → D, C, B, A, etc. can veto it
- An SSS-ranked member issues an order → No one can veto via rank (they're already highest) except for a general vote

#### 2. Governance Override (Democratic Veto)

**Any pending order can be blocked through a governance proposal vote.** This ensures that even orders issued by SSS-ranked members can be overridden by the community if a majority votes to block it.

```solidity
createProposalBlockOrder(uint64 orderId)
// Any F+ member can propose to block an order
// Requires standard quorum + majority to pass
// If passed, the order is blocked and the target is unlocked
```

This dual-protection system (rank-based + democratic) ensures that no single member has unchecked authority, while still allowing efficient day-to-day operations.

### Order Types

#### 1. Promotion Grants

A member proposes to promote another member one rank.

```solidity
issuePromotionGrant(uint32 targetId, Rank newRank)
// New rank must be <= issuerRank - 2 (can't promote above yourself)
// Target must accept via acceptPromotionGrant(orderId)
```

**Key:**
- Only higher-ranked members can issue promotions
- Target has flexibility - they can accept or decline
- Useful for mentorship and rank progression

#### 2. Demotion Orders

A member (≥2 ranks higher) can demote another member by one rank.

```solidity
issueDemotionOrder(uint32 targetId)
// Issuer must be >= 2 ranks above target
// Executes automatically after veto window
```

**Key:**
- No target consent needed (immediate after veto window)
- Used for enforcement and rule violations
- Can only demote by 1 rank at a time (sequential)

#### 3. Authority Orders

A member (≥2 ranks higher) can reassign another member's authority address.

```solidity
issueAuthorityOrder(uint32 targetId, address newAuthority)
// Useful for wallet recovery, multisig transitions, etc.
```

**Key:**
- Enables account recovery if private key is lost
- Can also reassign authority to a multisig or other contract
- Subject to veto like other orders

### Order Management Functions

```solidity
// Issue orders
issuePromotionGrant(uint32 targetId, Rank newRank)
issueDemotionOrder(uint32 targetId)
issueAuthorityOrder(uint32 targetId, address newAuthority)

// Accept (promotion only)
acceptPromotionGrant(uint64 orderId)

// Veto (higher-ranked members only)
blockOrder(uint64 orderId)

// Veto via governance (any F+ member can propose)
createProposalBlockOrder(uint64 orderId)

// Execute (after veto window + delay)
executeOrder(uint64 orderId)
```

---

## 🗳️ Governance Proposals (Global Voting)

Governance proposals enable the entire membership to vote on important decisions. Unlike orders (which are member-to-member), proposals use snapshot voting and require community consensus.

### Proposal Types

The DAO can vote on:

1. **Grant Rank** - Promote a member via democratic vote
2. **Demote Rank** - Remove a member's rank via vote
3. **Change Authority** - Reassign member's controlling wallet
4. **Block Order** - Block any pending order via democratic vote

### Proposal Eligibility

| Criterion | Requirement |
|-----------|-----------|
| **Proposer Rank** | F or higher |
| **Max Active Proposals** | Varies by rank (F=1, E=2, ..., SSS=9) |
| **Voting Period** | 7 days |
| **Passing Requires** | Quorum (20% participation) + Majority (yesVotes > noVotes) |

### Proposal Timeline

```
Day 0: Proposal Created
  ├─ Block snapshot taken
  └─ Voting enabled (1 block delay)
  
Days 0-7: Voting Window
  └─ Members cast votes
  
Day 7: Voting Ends
  └─ Anyone can finalize
  
Day 7-8: Execution Delay (24h)
  └─ Timelock enforced
  
Day 8+: Ready to Execute
  └─ Anyone can execute
```

### Core Proposal Functions

```solidity
// Create proposals
proposeGrantRank(uint32 targetId, Rank newRank)
proposeDemoteRank(uint32 targetId, Rank newRank)
proposeChangeAuthority(uint32 targetId, address newAuthority)

// Vote
castVote(uint64 proposalId, bool support)

// Finalize & Execute
finalize(uint64 proposalId)
execute(uint64 proposalId)
```

---

# 💰 MembershipTreasury Contract

The treasury management contract provides powerful fund controls paired with the RankedMembershipDAO membership system. It enables:

- **Democratic spending** - Members vote on large transactions
- **Delegated spending** - Treasurers handle routine fund management
- **Multi-asset support** - ETH, ERC20, ERC721, and arbitrary calls
- **Emergency controls** - Governance-controlled global transfer lock
- **Flexible treasury roles** - Member-based and address-based treasurers


# 💰 MembershipTreasury Contract

The treasury management contract provides powerful fund controls paired with the RankedMembershipDAO membership system. It enables:

- **Democratic spending** - Members vote on large transactions
- **Delegated spending** - Treasurers handle routine fund management
- **Multi-asset support** - ETH, ERC20, ERC721, and arbitrary calls
- **Emergency controls** - Governance-controlled global transfer lock
- **Flexible treasury roles** - Member-based and address-based treasurers

### Technical Overview

| Property | Value |
|----------|-------|
| **Contract** | `MembershipTreasury` |
| **Solidity** | `^0.8.24` |
| **Size** | ~2,181 lines |
| **Main Dependencies** | OpenZeppelin v5+, IRankedMembershipDAO interface |
| **Key Libraries** | Ownable2Step, Pausable, ReentrancyGuard, SafeERC20, Checkpoints |

### Governance Parameters

These are set via governance proposals (not owner functions):

| Parameter | Default | Purpose |
|-----------|---------|---------|
| **votingPeriod** | 7 days | Duration of voting windows |
| **quorumBps** | 20% | Minimum voting participation required |
| **executionDelay** | 24 hours | Timelock after proposal passes |
| **callActionsEnabled** | false | Whether arbitrary Call actions are allowed |
| **treasurerCallsEnabled** | false | Whether treasurers can execute calls |

---

## 📥 Deposits & Fund Management

The treasury receives funds through multiple channels:

### ETH Deposits

```solidity
receive() external payable
// Simply send ETH to the contract address
// Emits: DepositedETH(from, amount)
```

**Use Cases:**
- Direct ETH transfers from community members
- Yield from external protocols
- Grant funding

### ERC20 Token Deposits

```solidity
depositERC20(address token, uint256 amount)
// Requires: token approval from sender
// Emits: DepositedERC20(token, from, amount)
```

**Use Cases:**
- Stablecoins (USDC, DAI, etc.)
- Utility tokens
- Governance tokens

### NFT Deposits

The treasury can hold and manage ERC721 NFTs:

```solidity
// Direct call
depositNFT(address nftContract, uint256 tokenId)

// Or via safeTransferFrom
onERC721Received(address, address from, uint256 tokenId, bytes data)
// Emits: DepositedNFT(nftContract, from, tokenId)
```

**Use Cases:**
- Community art and collectibles
- Membership badges
- Governance tokens with NFT utility

---

## 🎁 Proposal-Based Spending

For significant treasury actions, the entire membership votes to approve spending.

### Action Types

The treasury supports multiple action types, enabling flexible governance:

| Action | Description | Who Votes? |
|--------|-------------|-----------|
| `TransferETH` | Send ETH to recipient | All members |
| `TransferERC20` | Send tokens to recipient | All members |
| `TransferNFT` | Send specific NFT to recipient | All members |
| `Call` | Execute arbitrary call (if enabled) | All members |
| `SetCallActionsEnabled` | Enable/disable Call actions | All members |
| `SetTreasurerCallsEnabled` | Enable/disable treasurer calls | All members |
| `AddApprovedCallTarget` | Add to call whitelist | All members |
| `RemoveApprovedCallTarget` | Remove from call whitelist | All members |
| `SetTransfersLocked` | Globally lock all transfers (emergency) | All members |

### Proposal Timeline

```
Day 0: Proposal Created
  └─ Included in next voting batch

Days 0-7: Voting Window
  └─ Members cast votes using snapshot power
  
Day 7: Voting Ends
  └─ Anyone calls finalize()
  
Day 7-8: Execution Delay (24h timelock)
  └─ Prevents rushed execution
  
Day 8+: Ready to Execute
  └─ Anyone calls execute()
  └─ Funds transferred if passed
```

### Creating Proposals

```solidity
// Spending proposals
proposeTransferETH(address to, uint256 amount)
proposeTransferERC20(address token, address to, uint256 amount)
proposeTransferNFT(address nftContract, address to, uint256 tokenId)
proposeCall(address target, uint256 value, bytes calldata data)

// Settings governance
proposeSetCallActionsEnabled(bool enabled)
proposeSetTreasurerCallsEnabled(bool enabled)
proposeAddApprovedCallTarget(address target)
proposeRemoveApprovedCallTarget(address target)
proposeSetTransfersLocked(bool locked)

// Treasurer management
proposeAddMemberTreasurer(uint32 memberId, ...)
proposeUpdateMemberTreasurer(uint32 memberId, ...)
proposeRemoveMemberTreasurer(uint32 memberId)
proposeAddAddressTreasurer(address treasurer, ...)
proposeUpdateAddressTreasurer(address treasurer, ...)
proposeRemoveAddressTreasurer(address treasurer)

// NFT access control
proposeGrantMemberNFTAccess(uint32 memberId, address nftContract, ...)
proposeRevokeMemberNFTAccess(uint32 memberId, address nftContract)
proposeGrantAddressNFTAccess(address treasurer, address nftContract, ...)
proposeRevokeAddressNFTAccess(address treasurer, address nftContract)
```

### Voting & Finalization

```solidity
// Cast your vote (during voting window)
castVote(uint64 proposalId, bool support)
// support=true for YES, support=false for NO

// Finalize after voting ends
finalize(uint64 proposalId)
// Sets proposal status to passed/failed + calculates execution delay

// Execute after timelock expires
execute(uint64 proposalId)
// Transfers funds or updates settings
```

---

## 👥 Treasurer System

Treasurers handle routine spending without requiring full proposal votes, subject to preapproved limits.

### Treasurer Concept

A **treasurer** is an authorized entity (member or address) who can spend up to preset limits per period:

```
Treasury Fund
    ├─ Proposal Voting (for large/unusual spending)
    └─ Treasurer Allowances (for routine spending)
        ├─ Member-based (rank-dependent limits)
        └─ Address-based (fixed limits)
```

**Benefits:**
- Fast, routine spending for operational needs
- No vote required for routine operations
- Clear, auditable spending limits
- Automatic period resets

### Two Treasurer Types

#### Member-Based Treasurers

Treasurers linked to DAO members. Spending limits scale with the member's current rank.

**Key Features:**
- Limits depend on member's rank (higher rank = higher spending power)
- If member is demoted, treasurer access can be suspended
- Includes a minimum rank requirement for operation
- Separate token limits per ERC20

**Configuration:**
```solidity
struct TreasurerConfig {
    uint256 baseSpendingLimit;           // Base ETH per period
    uint256 spendingLimitPerRankPower;   // Additional ETH per voting power unit
    uint64 periodDuration;               // e.g., 1 day
    Rank minRank;                        // Minimum required rank to spend
}
```

**Spending Formula:**
$$\text{ethLimit} = \text{baseLimit} + (\text{perRankPower} \times \text{votingPower})$$

**Example:**
- Member (rank A, voting power 64) with base 1 ETH, per-power 0.01 ETH
- Monthly limit = 1 + (0.01 × 64) = 1.64 ETH/month

#### Address-Based Treasurers

Treasurers with fixed spending limits, not tied to DAO membership.

**Key Features:**
- Fixed spending limit (no rank dependency)
- Can be EOA, multisig, or contract address
- Perfect for service accounts or external integrations
- Simpler configuration

**Configuration:**
```solidity
struct TreasurerConfig {
    uint256 baseSpendingLimit;  // Fixed ETH per period
    uint64 periodDuration;       // e.g., 1 week
}
```

### Managing Treasurers

All treasurer actions go through governance voting:

```solidity
// Member-based treasurers
proposeAddMemberTreasurer(
    uint32 memberId,
    uint256 baseSpendingLimit,
    uint256 spendingLimitPerRankPower,
    uint64 periodDuration,
    Rank minRank
)

proposeUpdateMemberTreasurer(
    uint32 memberId,
    uint256 baseSpendingLimit,
    uint256 spendingLimitPerRankPower,
    uint64 periodDuration,
    Rank minRank
)

proposeRemoveMemberTreasurer(uint32 memberId)

// Address-based treasurers
proposeAddAddressTreasurer(
    address treasurer,
    uint256 baseSpendingLimit,
    uint64 periodDuration
)

proposeUpdateAddressTreasurer(
    address treasurer,
    uint256 baseSpendingLimit,
    uint64 periodDuration
)

proposeRemoveAddressTreasurer(address treasurer)
```

### Direct Treasurer Spending

Once approved, treasurers can spend without voting:

```solidity
// ETH spending (within period limit)
treasurerSpendETH(address to, uint256 amount)

// ERC20 spending (within token-specific limit)
treasurerSpendERC20(address token, address to, uint256 amount)

// Authorized contract calls (requires target in whitelist)
treasurerCall(address target, uint256 value, bytes calldata data)
```

**Spending Limit Reset:** Automatically rolls over every `periodDuration` seconds

### Token-Specific Limits

Treasurers can have separate per-token limits (e.g., 1,000 USDC/month):

```solidity
// Set token limit for member-based treasurer
proposeSetMemberTreasurerTokenConfig(
    uint32 memberId,
    address token,
    uint256 baseLimit,
    uint256 limitPerRankPower
)

// Set token limit for address-based treasurer
proposeSetAddressTreasurerTokenConfig(
    address treasurer,
    address token,
    uint256 limit
)
```

### Treasurer View Functions

```solidity
// Check if address is a treasurer and get type
isTreasurer(address spender)
  returns (bool, TreasurerType)

// Get treasurer configuration
getMemberTreasurerConfig(uint32 memberId)
getAddressTreasurerConfig(address treasurer)

// Check remaining limit for current period
getTreasurerRemainingLimit(address spender)
getTreasurerRemainingTokenLimit(address spender, address token)
```

---

## 🏛️ NFT Management

The treasury can hold, manage, and distribute NFTs with fine-grained access controls.

### NFT Access Control

Treasurers can be granted permission to transfer specific NFT collections:

```solidity
struct NFTAccessConfig {
    bool hasAccess;           // Can transfer from this collection
    uint64 transfersPerPeriod; // 0 = unlimited
    uint64 periodDuration;     // Reset interval
    Rank minRank;             // (member-based only)
}
```

### Granting NFT Access

```solidity
// Member-based NFT access
proposeGrantMemberNFTAccess(
    uint32 memberId,
    address nftContract,
    uint64 transfersPerPeriod,
    uint64 periodDuration,
    Rank minRank
)

// Address-based NFT access
proposeGrantAddressNFTAccess(
    address treasurer,
    address nftContract,
    uint64 transfersPerPeriod,
    uint64 periodDuration
)

// Revoke access
proposeRevokeMemberNFTAccess(uint32 memberId, address nftContract)
proposeRevokeAddressNFTAccess(address treasurer, address nftContract)
```

### NFT Transfers

```solidity
// Treasurer can transfer if authorized for that collection
treasurerTransferNFT(
    address nftContract,
    address to,
    uint256 tokenId
)

// Regular proposal for any NFT in treasury
proposeTransferNFT(
    address nftContract,
    address to,
    uint256 tokenId
)
```

---

## 🚨 Emergency Control: Global Transfer Lock

The DAO can vote to globally freeze all transfers in emergency situations.

### How It Works

```solidity
// Proposal to lock transfers
proposeSetTransfersLocked(bool locked)
// Requires vote and execution delay

// Blocks all:
treasurerSpendETH()
treasurerSpendERC20()
treasurerTransferNFT()
execute(TransferETH)
execute(TransferERC20)
execute(TransferNFT)
```

**Use Cases:**
- Security incident detection
- Bridge/smart contract vulnerability
- Emergency fund preservation during governance crisis

---

## ⚙️ Configuration & Security

### Owner Functions

| Function | Effect |
|----------|--------|
| `pause()` | Freeze all operations (emergency) |
| `unpause()` | Resume operations |

**Note:** Most treasury settings are now controlled via governance proposals, not owner functions, to ensure democratic control.

### Security Layers

The treasury implements multiple security layers:

1. **Voting Requirements** - All spending decisions require member votes
2. **Execution Delays** - 24-hour timelock prevents rushed execution  
3. **Spending Limits** - Treasurers have capped, resetting allowances
4. **Rank Requirements** - Member treasurers need minimum rank
5. **Call Whitelist** - Treasurer calls limited to approved targets
6. **Snapshot Voting** - Voting power locked at block height (no flash loans)
7. **ReentrancyGuard** - Protection against reentrancy attacks
8. **Pausable** - Emergency stop for all operations
9. **Transfer Lock** - Governance-controlled global spending freeze

---

## 📊 Events & Transparency

### Deposit Events
- `DepositedETH(address indexed from, uint256 amount)`
- `DepositedERC20(address indexed token, address indexed from, uint256 amount)`
- `DepositedNFT(address indexed nftContract, address indexed from, uint256 tokenId)`

### Proposal Events
- `TreasuryProposalCreated(uint64 id, address proposer, ActionType actionType, ...)`
- `TreasuryVoteCast(uint64 indexed proposalId, uint32 indexed voterId, bool support, uint224 weight)`
- `TreasuryProposalFinalized(uint64 indexed proposalId, bool succeeded, uint224 yesVotes, uint224 noVotes, uint64 executableAfter)`
- `TreasuryProposalExecuted(uint64 indexed proposalId)`

### Spending Events
- `TreasurerSpent(address indexed spender, TreasurerType, address indexed recipient, address indexed token, uint256 amount)`
- `TreasurerCallExecuted(address indexed spender, TreasurerType, address indexed target, uint256 value, bytes data)`
- `TreasurerNFTTransferred(address indexed spender, TreasurerType, address indexed nftContract, address indexed to, uint256 tokenId)`

### Settings Events
- `CallActionsEnabledSet(bool enabled)`
- `TreasurerCallsEnabledSet(bool enabled)`
- `ApprovedCallTargetAdded(address indexed target)`
- `ApprovedCallTargetRemoved(address indexed target)`
- `TransfersLockedSet(bool locked)`
- `NFTTransferred(address indexed nftContract, address indexed to, uint256 tokenId)`

---

## 🎯 Quick Start Reference

### For MembersproposeSetAddressTreasurerTokenConfig(address treasurer, address token, uint256 limit)
\`\`\`

### Direct Treasurer Spending

Once approved, treasurers can spend directly:

\`\`\`solidity
// Spend ETH (within limits)
treasurerSpendETH(address to, uint256 amount)

// Spend ERC20 (within limits)
treasurerSpendERC20(address token, address to, uint256 amount)
\`\`\`

### Treasurer View Functions

\`\`\`solidity
getMemberTreasurerConfig(uint32 memberId) returns (TreasurerConfig)
getAddressTreasurerConfig(address treasurer) returns (TreasurerConfig)
getTreasurerRemainingLimit(address spender) returns (uint256 remaining)
getTreasurerRemainingTokenLimit(address spender, address token) returns (uint256 remaining)
isTreasurer(address spender) returns (bool, TreasurerType)
\`\`\`

---

## NFT Treasurer Access

NFT access is managed separately from fungible token spending limits. Treasurers can be granted access to specific NFT collections.

### NFT Access Configuration

| Field | Description |
|-------|-------------|
| \`hasAccess\` | Whether treasurer can transfer NFTs from this collection |
| \`transfersPerPeriod\` | Max transfers per period (0 = unlimited) |
| \`periodDuration\` | Reset period in seconds |
| \`minRank\` | Minimum rank required (member-based only) |

### Managing NFT Access (Proposal-Based)

\`\`\`solidity
// Member-based NFT access
proposeGrantMemberNFTAccess(uint32 memberId, address nftContract, uint64 transfersPerPeriod, uint64 periodDuration, Rank minRank)
proposeRevokeMemberNFTAccess(uint32 memberId, address nftContract)

// Address-based NFT access
proposeGrantAddressNFTAccess(address treasurer, address nftContract, uint64 transfersPerPeriod, uint64 periodDuration)
proposeRevokeAddressNFTAccess(address treasurer, address nftContract)
\`\`\`

### Direct NFT Transfers (Treasurer)

\`\`\`solidity
// Transfer NFT if authorized for that collection
treasurerTransferNFT(address nftContract, address to, uint256 tokenId)

// Execute call on approved contract (within ETH spending limits)
treasurerCall(address target, uint256 value, bytes calldata data)
\`\`\`

### Treasurer Calls

Treasurers can execute arbitrary calls on pre-approved contracts. This requires:
1. \`treasurerCallsEnabled\` must be true (set via governance vote)
2. Target contract must be in \`approvedCallTargets\` whitelist (added via governance vote)
3. ETH value sent with the call counts against the treasurer's spending limit

This allows treasurers to interact with DeFi protocols, bridges, or other contracts without requiring a full proposal vote for each interaction.

### NFT View Functions

\`\`\`solidity
ownsNFT(address nftContract, uint256 tokenId) returns (bool)
getMemberNFTAccess(uint32 memberId, address nftContract) returns (NFTAccessConfig)
getAddressNFTAccess(address treasurer, address nftContract) returns (NFTAccessConfig)
getMemberNFTRemainingTransfers(uint32 memberId, address nftContract) returns (uint64)
getAddressNFTRemainingTransfers(address treasurer, address nftContract) returns (uint64)
hasNFTAccess(address spender, address nftContract) returns (bool, TreasurerType)
\`\`\`

---

## Optional Spending Caps

The owner can enable global daily spending caps as an additional safety measure:

\`\`\`solidity
setCapsEnabled(bool enabled)
setDailyCap(address asset, uint256 cap)  // asset=address(0) for ETH
\`\`\`

When enabled, proposal executions are subject to daily caps regardless of vote outcome.

---

## Settings Governance

Critical treasury settings are controlled through governance proposals, not owner functions:

### Call Actions Settings

\`\`\`solidity
// Enable/disable arbitrary Call proposals (dangerous - disabled by default)
proposeSetCallActionsEnabled(bool enabled) returns (uint64 proposalId)

// Enable/disable treasurer Call functionality
proposeSetTreasurerCallsEnabled(bool enabled) returns (uint64 proposalId)
\`\`\`

### Approved Call Targets

Treasurers can only execute calls on contracts in the approved whitelist:

\`\`\`solidity
// Add contract to approved call targets whitelist
proposeAddApprovedCallTarget(address target) returns (uint64 proposalId)

// Remove contract from approved call targets whitelist
proposeRemoveApprovedCallTarget(address target) returns (uint64 proposalId)
\`\`\`

This ensures all treasury configuration changes require member consensus.

---

---

## 🎯 Quick Start Reference

### For DAO Members

**Membership Actions:**
```solidity
issueInvite(address to)                              // Invite someone
acceptInvite(uint64 inviteId)                        // Join via invite
reclaimExpiredInvite(uint64 inviteId)                // Reclaim unused invite
changeMyAuthority(address newAuthority)              // Update your authority
```

**Timelocked Orders (Member Management):**
```solidity
issuePromotionGrant(uint32 targetId, Rank newRank)  // Propose rank increase
acceptPromotionGrant(uint64 orderId)                 // Accept promotion offer
issueDemotionOrder(uint32 targetId)                  // Demote (if authorized)
issueAuthorityOrder(uint32 targetId, address new)   // Reassign authority
blockOrder(uint64 orderId)                           // Veto a pending order
executeOrder(uint64 orderId)                         // Execute after delay
```

**Governance Proposals:**
```solidity
proposeGrantRank(uint32 targetId, Rank newRank)     // Vote to promote
proposeDemoteRank(uint32 targetId, Rank newRank)    // Vote to demote
proposeChangeAuthority(uint32 targetId, address new) // Vote to reassign
castVote(uint64 proposalId, bool support)           // Cast your vote
finalize(uint64 proposalId)                         // Finalize after voting
```

### For Treasury Spending

**Deposit Funds:**
```solidity
// ETH - just send to contract
receive()

// ERC20 - needs approval first
depositERC20(address token, uint256 amount)

// NFTs
depositNFT(address nftContract, uint256 tokenId)
```

**Propose Spending:**
```solidity
proposeTransferETH(address to, uint256 amount)
proposeTransferERC20(address token, address to, uint256 amount)
proposeTransferNFT(address nftContract, address to, uint256 tokenId)
proposeCall(address target, uint256 value, bytes calldata data)

// Settings
proposeSetTransfersLocked(bool locked)               // Emergency freeze
```

**Treasurer Management:**
```solidity
proposeAddMemberTreasurer(uint32 memberId, ...)
proposeUpdateMemberTreasurer(uint32 memberId, ...)
proposeRemoveMemberTreasurer(uint32 memberId)

proposeAddAddressTreasurer(address treasurer, ...)
proposeUpdateAddressTreasurer(address treasurer, ...)
proposeRemoveAddressTreasurer(address treasurer)
```

**Treasurer Direct Spending (if authorized):**
```solidity
treasurerSpendETH(address to, uint256 amount)
treasurerSpendERC20(address token, address to, uint256 amount)
treasurerTransferNFT(address nftContract, address to, uint256 tokenId)
treasurerCall(address target, uint256 value, bytes calldata data)
```

### For Treasury Queries

```solidity
// Check balance
balanceETH()
balanceERC20(address token)

// Check NFT ownership
ownsNFT(address nftContract, uint256 tokenId)

// Check treasurer status
isTreasurer(address spender)
getTreasurerRemainingLimit(address spender)
getTreasurerRemainingTokenLimit(address spender, address token)

// Check NFT access
hasNFTAccess(address spender, address nftContract)
getMemberNFTRemainingTransfers(uint32 memberId, address nftContract)
```

---

## 📋 Updates & Improvements

### Latest Security Fixes (v1.0)

✅ **Critical [C-01]** - Call Action Target Whitelist enforcement  
✅ **High [H-01]** - Flash Loan Voting Attack Prevention (1-block delay)  
✅ **High [H-02]** - Treasurer Period Reset Bug Fix  
✅ **Medium [M-01]** - Minimum Quorum (1 vote) Requirement  
✅ **Medium [M-04]** - Spending Limit Per Rank Cap  
✅ **Medium [M-07]** - Treasurer NFT Ownership Check

### Recent Enhancements

🎁 **Global Transfer Lock** - Governance can freeze all transfers in emergencies  
🔒 **Enhanced Treasury Security** - Voting power snapshots prevent flash loan attacks  
⚙️ **Governance-Controlled Settings** - Critical parameters managed by DAO votes  
📊 **Comprehensive Audit Trail** - Full event logging for transparency  

See `CHANGELOG.md` for complete history and `AUDIT.md` for security details.

---

## 📚 Documentation

- **`AUDIT.md`** - Complete security audit report with findings and resolutions
- **`CHANGELOG.md`** - Version history, fixes, and new features
- **`RankedMembershipDAO.sol`** - Core membership and governance contract
- **`MembershipTreasury.sol`** - Treasury management contract

---

## 💡 Architecture Highlights

### Design Principles

1. **Decentralization** - No centralized admin; membership controls everything
2. **Transparency** - All actions logged via events; no hidden spending
3. **Safety** - Multiple security layers (voting, timelocks, limits, snapshots)
4. **Flexibility** - Supports diverse asset types and spending models
5. **Scalability** - Efficient snapshot voting, no on-chain state explosion

### Key Trade-offs

| Aspect | Choice | Rationale |
|--------|--------|-----------|
| **Voting Power** | Exponential (2^rank) | Scales with trust level; prevents dilution at higher ranks |
| **Execution Delay** | 24-hour fixed | Provides time to detect/react to malicious proposals |
| **Veto Mechanism** | Rank-based (+2 ranks) | Prevents abuse by lower ranks; reasonable governance friction |
| **Invite Epochs** | 100 days | Long enough for strategic planning; prevents gaming |
| **Treasury Proposal Voting** | 7 days | Extended window for broader participation |

---

## 🚀 Deployment

### Prerequisites

- Solidity ^0.8.24
- OpenZeppelin Contracts v5+
- Web3 provider (Ethereum-compatible network)

### Initialization Steps

1. Deploy `RankedMembershipDAO` contract
   - Deployer automatically becomes SSS rank member and owner
2. Deploy `MembershipTreasury` contract
   - Pass `RankedMembershipDAO` address as immutable param
3. Call `finalizeBootstrap()` to lock bootstrap phase
4. Initialize treasurers via governance proposals
5. Begin operations

See deployment files for specific instructions.

---

## 📞 Support & Community

For questions about:
- **Usage** - See function docstrings in contracts
- **Security** - Review `AUDIT.md` and security findings
- **Integration** - Reference the `Quick Start` section above
- **Issues** - Check `CHANGELOG.md` for known issues and fixes

---

## License

MIT - See LICENSE file for details

```