// Human-readable ABIs for ethers v6.
// Only the functions/events the frontend needs.

export const DAO_ABI = [
  // ── Constants ────────────────────────────────
  "function EPOCH() view returns (uint64)",

  // ── Governance params ────────────────────────
  "function inviteExpiry() view returns (uint64)",
  "function orderDelay() view returns (uint64)",
  "function votingPeriod() view returns (uint64)",
  "function quorumBps() view returns (uint16)",
  "function executionDelay() view returns (uint64)",

  // ── Fee config ───────────────────────────────
  "function feeToken() view returns (address)",
  "function baseFee() view returns (uint256)",
  "function gracePeriod() view returns (uint64)",
  "function payoutTreasury() view returns (address)",

  // ── Membership ───────────────────────────────
  "function nextMemberId() view returns (uint32)",
  "function getMember(uint32 memberId) view returns (tuple(bool exists, uint32 id, uint8 rank, address authority, uint64 joinedAt))",
  "function memberIdByAuthority(address) view returns (uint32)",
  "function membersById(uint32 id) view returns (bool exists, uint32 id, uint8 rank, address authority, uint64 joinedAt)",

  // ── Voting power ─────────────────────────────
  "function totalVotingPower() view returns (uint224)",
  "function votingPowerOfMember(uint32 memberId) view returns (uint224)",
  "function votingPowerOfRank(uint8 rank) view returns (uint224)",
  "function inviteAllowanceOfRank(uint8 rank) view returns (uint16)",
  "function proposalLimitOfRank(uint8 rank) view returns (uint8)",
  "function orderLimitOfRank(uint8 rank) view returns (uint8)",

  // ── Fee state ────────────────────────────────
  "function memberActive(uint32) view returns (bool)",
  "function feePaidUntil(uint32) view returns (uint64)",
  "function feeOfRank(uint8 rank) view returns (uint256)",
  "function isMemberActive(uint32 memberId) view returns (bool)",

  // ── Admin / info ─────────────────────────────
  "function owner() view returns (address)",
  "function controller() view returns (address)",
  "function feeRouter() view returns (address)",
  "function bootstrapFinalized() view returns (bool)",
  "function paused() view returns (bool)",

  // ── Self-service ─────────────────────────────
  "function changeMyAuthority(address newAuthority)",
  "function deactivateMember(uint32 memberId)",

  // ── Events ───────────────────────────────────
  "event MemberJoined(uint32 indexed memberId, address indexed authority, uint8 rank)",
  "event RankChanged(uint32 indexed memberId, uint8 oldRank, uint8 newRank, uint32 byMemberId, bool viaGovernance)",
  "event AuthorityChanged(uint32 indexed memberId, address indexed oldAuthority, address indexed newAuthority, uint32 byMemberId, bool viaGovernance)",
  "event FeePaid(uint32 indexed memberId, uint64 paidUntil)",
  "event MemberDeactivated(uint32 indexed memberId)",
  "event MemberReactivated(uint32 indexed memberId)",
  "event BootstrapMember(uint32 indexed memberId, address indexed authority, uint8 rank)",
  "event BootstrapFinalized()",
];

export const GOVERNANCE_ABI = [
  // ── References ───────────────────────────────
  "function dao() view returns (address)",

  // ── Counters ─────────────────────────────────
  "function nextInviteId() view returns (uint64)",
  "function nextOrderId() view returns (uint64)",
  "function nextProposalId() view returns (uint64)",

  // ── State queries ────────────────────────────
  "function activeOrdersOf(uint32) view returns (uint16)",
  "function activeProposalsOf(uint32) view returns (uint16)",
  "function pendingOrderOfTarget(uint32) view returns (uint64)",
  "function hasVoted(uint64, uint32) view returns (bool)",
  "function invitesUsedByEpoch(uint32, uint64) view returns (uint16)",

  // ── Struct getters ───────────────────────────
  "function getInvite(uint64 inviteId) view returns (tuple(bool exists, uint64 inviteId, uint32 issuerId, address to, uint64 issuedAt, uint64 expiresAt, uint64 epoch, bool claimed, bool reclaimed))",
  "function getOrder(uint64 orderId) view returns (tuple(bool exists, uint64 orderId, uint8 orderType, uint32 issuerId, uint8 issuerRankAtCreation, uint32 targetId, uint8 newRank, address newAuthority, uint64 createdAt, uint64 executeAfter, bool blocked, bool executed, uint32 blockedById))",
  "function getProposal(uint64 proposalId) view returns (tuple(bool exists, uint64 proposalId, uint8 proposalType, uint32 proposerId, uint32 targetId, uint8 rankValue, address addressValue, uint64 parameterValue, uint64 orderIdToBlock, address erc20Token, uint256 erc20Amount, address erc20Recipient, uint32 snapshotBlock, uint64 startTime, uint64 endTime, uint224 yesVotes, uint224 noVotes, bool finalized, bool succeeded))",

  // ── Invite actions ───────────────────────────
  "function issueInvite(address to) returns (uint64)",
  "function acceptInvite(uint64 inviteId) returns (uint32)",
  "function reclaimExpiredInvite(uint64 inviteId)",

  // ── Order actions ────────────────────────────
  "function issuePromotionGrant(uint32 targetId, uint8 newRank) returns (uint64)",
  "function issueDemotionOrder(uint32 targetId) returns (uint64)",
  "function issueAuthorityOrder(uint32 targetId, address newAuthority) returns (uint64)",
  "function acceptPromotionGrant(uint64 orderId)",
  "function executeOrder(uint64 orderId)",
  "function blockOrder(uint64 orderId)",
  "function rescindOrder(uint64 orderId)",

  // ── Proposal creation ────────────────────────
  "function createProposalGrantRank(uint32 targetId, uint8 newRank) returns (uint64)",
  "function createProposalDemoteRank(uint32 targetId, uint8 newRank) returns (uint64)",
  "function createProposalChangeAuthority(uint32 targetId, address newAuthority) returns (uint64)",
  "function createProposalChangeParameter(uint8 pType, uint64 newValue) returns (uint64)",
  "function createProposalBlockOrder(uint64 orderId) returns (uint64)",
  "function createProposalTransferERC20(address token, uint256 amount, address recipient) returns (uint64)",

  // ── Proposal actions ─────────────────────────
  "function castVote(uint64 proposalId, bool support)",
  "function finalizeProposal(uint64 proposalId)",

  // ── Events ───────────────────────────────────
  "event InviteIssued(uint64 indexed inviteId, uint32 indexed issuerId, address indexed to, uint64 expiresAt, uint64 epoch)",
  "event InviteClaimed(uint64 indexed inviteId, uint32 indexed newMemberId, address indexed authority)",
  "event InviteReclaimed(uint64 indexed inviteId, uint32 indexed issuerId)",
  "event OrderCreated(uint64 indexed orderId, uint8 orderType, uint32 indexed issuerId, uint32 indexed targetId, uint8 newRank, address newAuthority, uint64 executeAfter)",
  "event OrderBlocked(uint64 indexed orderId, uint32 indexed blockerId)",
  "event OrderBlockedByGovernance(uint64 indexed orderId, uint64 indexed proposalId)",
  "event OrderExecuted(uint64 indexed orderId)",
  "event OrderRescinded(uint64 indexed orderId, uint32 indexed issuerId)",
  "event ProposalCreated(uint64 indexed proposalId, uint8 proposalType, uint32 indexed proposerId, uint32 indexed targetId)",
  "event VoteCast(uint64 indexed proposalId, uint32 indexed voterId, bool support, uint224 weight)",
  "event ProposalFinalized(uint64 indexed proposalId, bool succeeded, uint224 yesVotes, uint224 noVotes)",
];

export const TREASURY_ABI = [
  "function dao() view returns (address)",
  "function treasurerModule() view returns (address)",
  "function nextProposalId() view returns (uint64)",
  "function getProposal(uint64 proposalId) view returns (uint64 id, uint32 proposerId, uint8 proposerRank, uint32 snapshotBlock, uint64 startTime, uint64 endTime, uint224 yesVotes, uint224 noVotes, bool finalized, bool succeeded, uint64 executableAfter, bool executed, uint8 actionType)",
  "function getProposalData(uint64 proposalId) view returns (bytes)",
  "function hasVoted(uint64, uint32) view returns (bool)",
  "function activeProposalsOf(uint32) view returns (uint16)",
  "function balanceETH() view returns (uint256)",
  "function balanceERC20(address token) view returns (uint256)",
  "function treasuryLocked() view returns (bool)",
  "function callActionsEnabled() view returns (bool)",
  "function capsEnabled() view returns (bool)",
  "function dailyCap(address) view returns (uint256)",
  "function propose(uint8 actionType, bytes data) returns (uint64)",
  "function castVote(uint64 proposalId, bool support)",
  "function finalize(uint64 proposalId)",
  "function execute(uint64 proposalId)",
  "function depositERC20(address token, uint256 amount)",
  "event DepositedETH(address indexed from, uint256 amount)",
  "event DepositedERC20(address indexed token, address indexed from, uint256 amount)",
  "event ProposalCreated(uint64 indexed proposalId, uint32 indexed proposerId, uint8 actionType, uint64 startTime, uint64 endTime, uint32 snapshotBlock)",
  "event VoteCast(uint64 indexed proposalId, uint32 indexed voterId, bool support, uint224 weight)",
  "event ProposalFinalized(uint64 indexed proposalId, bool succeeded, uint224 yesVotes, uint224 noVotes, uint64 executableAfter)",
  "event ProposalExecuted(uint64 indexed proposalId)",
];

export const FEE_ROUTER_ABI = [
  "function dao() view returns (address)",
  "function payMembershipFee(uint32 memberId) payable",
  "event MembershipFeePaid(uint32 indexed memberId, address indexed payer, address feeToken, uint256 amount, address payoutTreasury)",
];

export const ERC20_ABI = [
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
];
