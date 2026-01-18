# Guild DAO System

A comprehensive membership-controlled DAO with ranked governance and treasury management.

## System Overview

The Guild DAO consists of two main contracts:

1. **RankedMembershipDAO** - Membership management, ranks, invites, orders, and governance
2. **MembershipTreasury** - Treasury management with proposal-based spending, treasurer roles, and NFT support

---

# RankedMembershipDAO

A membership-controlled DAO smart contract with:
- 10 membership ranks (G → F → E → D → C → B → A → S → SS → SSS)
- Voting power that **doubles each rank**
- Invite-based onboarding with **24h expiry** and **100-day invite epochs**
- Timelocked member-management orders (promotion grants, demotions, authority recovery) with **24h delay + higher-rank veto**
- Snapshot-based governance proposals (grant rank, demote rank, change authority)

---

## Contract summary

**Contract:** \`RankedMembershipDAO\`  
**Solidity:** \`^0.8.24\`  
**Libraries:** OpenZeppelin (Ownable2Step, Pausable, ReentrancyGuard, SafeCast, Checkpoints)

### Rank ladder

\`G, F, E, D, C, B, A, S, SS, SSS\`

Internally the ranks map to indices \`0..9\`. Higher index = higher power.

### Voting power

Voting weight is:

\`votingPower(rank) = 2^rankIndex\`

So:
- G = 1
- F = 2
- E = 4
- …
- SSS = 512

Voting uses **snapshot power** recorded via OpenZeppelin \`Checkpoints\`. A proposal snapshots at its creation block, and votes are counted using the member's voting power at that snapshot block.

### Invite allowance

Invite allowance per epoch uses the same doubling model:

\`inviteAllowance(rank) = 2^rankIndex\`

Epoch length is fixed at **100 days**. Invite validity is fixed at **24 hours**.

---

## Deployment / bootstrap

On deployment:
- The deployer is bootstrapped as a member at rank **SSS**
- The deployer becomes \`owner\` (via \`Ownable2Step\`)

Bootstrap-only helpers exist for initial setup:
- \`bootstrapAddMember(address authority, Rank rank)\` (owner only)
- \`finalizeBootstrap()\` (owner only) → permanently ends bootstrap additions

Pausing:
- \`pause()\` / \`unpause()\` (owner only)

---

## Core concepts

### Member identity & authority

Each member has:
- a unique \`memberId\` (\`uint32\`)
- a \`rank\`
- an \`authority\` address

The **authority** address is the account that votes, proposes, issues invites, and issues orders. On join, the authority is the wallet that accepted the invite.

Members can:
- change their own authority immediately (\`changeMyAuthority\`)
- be assigned a new authority via a timelocked **AuthorityOrder** (wallet recovery workflow)
- be assigned a new authority via governance proposal **ChangeAuthority**

The contract enforces:
- one authority address maps to at most one \`memberId\` at any time

---

## Invites

### Flow

1. A member calls \`issueInvite(to)\`  
2. The invite reserves one invite "slot" in the issuer's current **100-day epoch**
3. The invite can be claimed by \`to\` within **24 hours** using \`acceptInvite(inviteId)\`
4. If it expires, the issuer calls \`reclaimExpiredInvite(inviteId)\` to restore the reserved slot

### Accounting rules

- On \`issueInvite\`, the contract increments \`invitesUsedByEpoch[issuerId][epoch]\` immediately.
- On \`acceptInvite\`, the invite becomes claimed and mints a new member at rank \`G\`.
- On \`reclaimExpiredInvite\`, the invite becomes reclaimed and the reserved slot is returned.

### Invite-related functions

- \`issueInvite(address to) returns (uint64 inviteId)\`
- \`acceptInvite(uint64 inviteId) returns (uint32 newMemberId)\`
- \`reclaimExpiredInvite(uint64 inviteId)\`

---

## Timelocked Orders (member-to-member)

Orders are "local" actions issued by one member about another member (or their authority). Every order has:
- **24 hour delay**
- a **veto window** during that 24 hours

### Single outstanding order invariant

A target member can have **one** pending order at a time.

### Veto rule

During the 24h window, an order can be blocked by a member whose rank is at least **two ranks above the issuer's rank at creation**:

\`blockerRank >= issuerRankAtCreation + 2\`

### Order types

1. **Promotion grant** - Issuer proposes new rank (at most issuerRank − 2), target must accept after 24h
2. **Demotion order** - Issuer must be ≥2 ranks above target, reduces rank by one step
3. **Authority order** - Issuer must be ≥2 ranks above target, schedules new authority address

---

## Governance proposals (global voting)

Governance proposals allow the whole membership to vote to:
1. **Grant rank to member** (promotion)
2. **Demote rank of member**
3. **Change authority** of member

### Eligibility & proposal limits

- Proposer must be at least rank **F**
- Each proposer has a cap on **active** proposals based on rank (F=1, E=2, ... SSS=9)

### Voting & finalization rules

- Voting window: **7 days**
- Passing requires:
  - **Quorum**: votes cast >= **20%** of total snapshot power
  - **Majority**: \`yesVotes > noVotes\`

---

# MembershipTreasury

A comprehensive treasury management contract linked to RankedMembershipDAO with:
- Proposal-based spending for ETH, ERC20, and NFT transfers
- **Treasurer system** with preapproved spending limits
- Two treasurer types: **Member-based** and **Address-based**
- Separate NFT access controls per collection
- 24-hour execution delay after proposal passes

---

## Contract summary

**Contract:** \`MembershipTreasury\`  
**Solidity:** \`^0.8.24\`  
**Libraries:** OpenZeppelin (Ownable2Step, Pausable, ReentrancyGuard, SafeCast, IERC20, IERC721)

### Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| \`VOTING_PERIOD\` | 7 days | Duration of voting window |
| \`QUORUM_BPS\` | 2000 (20%) | Minimum participation for valid vote |
| \`EXECUTION_DELAY\` | 24 hours | Timelock after proposal passes |

---

## Deposits

The treasury can receive:

### ETH
- Direct transfers via \`receive()\` function
- Emits \`DepositedETH(from, amount)\`

### ERC20 Tokens
- \`depositERC20(address token, uint256 amount)\`
- Requires prior approval
- Emits \`DepositedERC20(token, from, amount)\`

### NFTs (ERC721)
- \`depositNFT(address nftContract, uint256 tokenId)\`
- Also accepts \`safeTransferFrom\` via \`onERC721Received\`
- Emits \`DepositedNFT(nftContract, from, tokenId)\`

---

## Proposal-Based Spending

All treasury actions require member voting (except treasurer direct spending within limits).

### Action Types

| ActionType | Description |
|------------|-------------|
| \`TransferETH\` | Send ETH to an address |
| \`TransferERC20\` | Send ERC20 tokens to an address |
| \`TransferNFT\` | Send specific NFT (by tokenId) to an address |
| \`Call\` | Execute arbitrary call with ETH value and calldata |
| \`SetCallActionsEnabled\` | Enable/disable arbitrary Call proposals |
| \`SetTreasurerCallsEnabled\` | Enable/disable treasurer Call functionality |
| \`AddApprovedCallTarget\` | Add contract to treasurer call whitelist |
| \`RemoveApprovedCallTarget\` | Remove contract from treasurer call whitelist |

### Proposal Flow

1. **Create** - Member (rank F+) creates proposal
2. **Vote** - Members vote during 7-day window
3. **Finalize** - Anyone finalizes after voting ends
4. **Execute** - Anyone executes after 24-hour delay (if passed)

### Proposal Functions

\`\`\`solidity
// ETH transfer
proposeTransferETH(address to, uint256 amount) returns (uint64 proposalId)

// ERC20 transfer
proposeTransferERC20(address token, address to, uint256 amount) returns (uint64 proposalId)

// NFT transfer (includes specific tokenId)
proposeTransferNFT(address nftContract, address to, uint256 tokenId) returns (uint64 proposalId)

// Arbitrary call
proposeCall(address target, uint256 value, bytes calldata data) returns (uint64 proposalId)

// Voting
castVote(uint64 proposalId, bool support)

// Finalization & Execution
finalize(uint64 proposalId)
execute(uint64 proposalId)
\`\`\`

---

## Treasurer System

Treasurers can spend directly from the treasury within preapproved limits, without requiring a full proposal vote for each transaction.

### Two Treasurer Types

#### 1. Member-Based Treasurers

Linked to a DAO member ID. Authority is derived from the member's current rank in the DAO.

**Features:**
- Spending limits scale with rank (voting power)
- Minimum rank requirement enforced
- If member is demoted below minimum rank, treasurer access is suspended
- Limit formula: \`baseSpendingLimit + (spendingLimitPerRankPower × votingPower)\`

#### 2. Address-Based Treasurers

Direct authority granted to a specific address (can be EOA, multisig, or contract).

**Features:**
- Fixed spending limit
- Not tied to DAO membership
- Useful for external integrations, service accounts, or multisigs

### Treasurer Configuration

| Field | Description |
|-------|-------------|
| \`baseSpendingLimit\` | Base ETH limit per period (wei) |
| \`spendingLimitPerRankPower\` | Additional limit per voting power unit (member-based only) |
| \`periodDuration\` | Reset period in seconds (e.g., 1 day, 1 week) |
| \`minRank\` | Minimum rank required (member-based only) |

### Token-Specific Limits

Each treasurer can have separate limits per ERC20 token:
- \`baseLimit\` - Base token limit per period
- \`limitPerRankPower\` - Additional limit per voting power (member-based only)

### Managing Treasurers (Proposal-Based)

All treasurer management goes through voting:

\`\`\`solidity
// Member-based treasurers
proposeAddMemberTreasurer(uint32 memberId, uint256 baseSpendingLimit, uint256 spendingLimitPerRankPower, uint64 periodDuration, Rank minRank)
proposeUpdateMemberTreasurer(uint32 memberId, uint256 baseSpendingLimit, uint256 spendingLimitPerRankPower, uint64 periodDuration, Rank minRank)
proposeRemoveMemberTreasurer(uint32 memberId)
proposeSetMemberTreasurerTokenConfig(uint32 memberId, address token, uint256 baseLimit, uint256 limitPerRankPower)

// Address-based treasurers
proposeAddAddressTreasurer(address treasurer, uint256 baseSpendingLimit, uint64 periodDuration)
proposeUpdateAddressTreasurer(address treasurer, uint256 baseSpendingLimit, uint64 periodDuration)
proposeRemoveAddressTreasurer(address treasurer)
proposeSetAddressTreasurerTokenConfig(address treasurer, address token, uint256 limit)
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

## Admin Functions

| Function | Access | Description |
|----------|--------|-------------|
| \`pause()\` | Owner | Pause all operations |
| \`unpause()\` | Owner | Resume operations |
| \`setCapsEnabled(bool)\` | Owner | Enable/disable spending caps |
| \`setDailyCap(address, uint256)\` | Owner | Set daily cap for asset |

Note: \`callActionsEnabled\` and \`treasurerCallsEnabled\` are now controlled via governance proposals, not owner functions.

---

## Security Model

### Treasury Security Layers

1. **Proposal Voting** - All spending requires member vote (7 days)
2. **Execution Delay** - 24-hour timelock after passing
3. **Treasurer Limits** - Preapproved treasurers have capped spending
4. **Period Resets** - Treasurer limits reset periodically
5. **Rank Requirements** - Member-based treasurers need minimum rank
6. **Optional Caps** - Owner can enable global daily limits
7. **Pausable** - Owner can halt all operations in emergency

### Contract Security

- **ReentrancyGuard** on all state-changing functions
- **Pausable** for emergency stops
- **Ownable2Step** for safe owner transfers
- **Snapshot voting** prevents vote manipulation
- **Custom errors** for gas-efficient reverts

---

## Events

### Deposit Events
- \`DepositedETH(address indexed from, uint256 amount)\`
- \`DepositedERC20(address indexed token, address indexed from, uint256 amount)\`
- \`DepositedNFT(address indexed nftContract, address indexed from, uint256 tokenId)\`

### Proposal Events
- \`TreasuryProposalCreated(...)\`
- \`TreasuryVoteCast(uint64 indexed proposalId, uint32 indexed voterId, bool support, uint224 weight)\`
- \`TreasuryProposalFinalized(uint64 indexed proposalId, bool succeeded, uint224 yesVotes, uint224 noVotes, uint64 executableAfter)\`
- \`TreasuryProposalExecuted(uint64 indexed proposalId)\`

### Treasurer Events
- \`MemberTreasurerAdded/Updated/Removed\`
- \`AddressTreasurerAdded/Updated/Removed\`
- \`MemberTreasurerTokenConfigSet\`
- \`AddressTreasurerTokenConfigSet\`
- \`TreasurerSpent(address indexed spender, TreasurerType, address indexed recipient, address indexed token, uint256 amount)\`
- \`TreasurerCallExecuted(address indexed spender, TreasurerType, address indexed target, uint256 value, bytes data)\`

### Settings Events
- \`CallActionsEnabledSet(bool enabled)\`
- \`TreasurerCallsEnabledSet(bool enabled)\`
- \`ApprovedCallTargetAdded(address indexed target)\`
- \`ApprovedCallTargetRemoved(address indexed target)\`

### NFT Events
- \`NFTTransferred(address indexed nftContract, address indexed to, uint256 tokenId)\`
- \`MemberNFTAccessGranted/Revoked\`
- \`AddressNFTAccessGranted/Revoked\`
- \`TreasurerNFTTransferred(address indexed spender, TreasurerType, address indexed nftContract, address indexed to, uint256 tokenId)\`

---

## Quick Reference: DAO Entrypoints

### Member Actions
- \`issueInvite(to)\`
- \`acceptInvite(inviteId)\`
- \`reclaimExpiredInvite(inviteId)\`
- \`changeMyAuthority(newAuthority)\`

### Orders
- \`issuePromotionGrant(targetId, newRank)\`
- \`acceptPromotionGrant(orderId)\`
- \`issueDemotionOrder(targetId)\`
- \`issueAuthorityOrder(targetId, newAuthority)\`
- \`blockOrder(orderId)\`
- \`executeOrder(orderId)\`

### Governance
- \`createProposalGrantRank(targetId, newRank)\`
- \`createProposalDemoteRank(targetId, newRank)\`
- \`createProposalChangeAuthority(targetId, newAuthority)\`
- \`castVote(proposalId, support)\`
- \`finalizeProposal(proposalId)\`

---

## Quick Reference: Treasury Entrypoints

### Deposits
- \`receive()\` - ETH
- \`depositERC20(token, amount)\`
- \`depositNFT(nftContract, tokenId)\`

### Proposals (Spending)
- \`proposeTransferETH(to, amount)\`
- \`proposeTransferERC20(token, to, amount)\`
- \`proposeTransferNFT(nftContract, to, tokenId)\`
- \`proposeCall(target, value, data)\`

### Proposals (Treasurer Management)
- \`proposeAddMemberTreasurer(...)\`
- \`proposeUpdateMemberTreasurer(...)\`
- \`proposeRemoveMemberTreasurer(memberId)\`
- \`proposeAddAddressTreasurer(...)\`
- \`proposeUpdateAddressTreasurer(...)\`
- \`proposeRemoveAddressTreasurer(treasurer)\`
- \`proposeSetMemberTreasurerTokenConfig(...)\`
- \`proposeSetAddressTreasurerTokenConfig(...)\`

### Proposals (NFT Access)
- \`proposeGrantMemberNFTAccess(...)\`
- \`proposeRevokeMemberNFTAccess(memberId, nftContract)\`
- \`proposeGrantAddressNFTAccess(...)\`
- \`proposeRevokeAddressNFTAccess(treasurer, nftContract)\`

### Proposals (Settings Governance)
- \`proposeSetCallActionsEnabled(enabled)\`
- \`proposeSetTreasurerCallsEnabled(enabled)\`
- \`proposeAddApprovedCallTarget(target)\`
- \`proposeRemoveApprovedCallTarget(target)\`

### Voting & Execution
- \`castVote(proposalId, support)\`
- \`finalize(proposalId)\`
- \`execute(proposalId)\`

### Treasurer Direct Spending
- \`treasurerSpendETH(to, amount)\`
- \`treasurerSpendERC20(token, to, amount)\`
- \`treasurerTransferNFT(nftContract, to, tokenId)\`
- \`treasurerCall(target, value, data)\` - requires enabled + approved target

### Views
- \`getProposal(proposalId)\`
- \`balanceETH()\`
- \`balanceERC20(token)\`
- \`ownsNFT(nftContract, tokenId)\`
- \`isTreasurer(address)\`
- \`getTreasurerRemainingLimit(address)\`
- \`hasNFTAccess(address, nftContract)\`
- \`callActionsEnabled\` - whether Call proposals can execute
- \`treasurerCallsEnabled\` - whether treasurers can use treasurerCall
- \`approvedCallTargets(address)\` - whether address is approved for treasurer calls

---

## License

MIT
