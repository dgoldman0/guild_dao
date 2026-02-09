import { id as keccak256 } from "ethers";

/*
  Solidity custom-error decoder for The Guild DAO contracts.

  Maps 4-byte selectors to human-readable titles + actionable descriptions.
  Covers all custom errors across RankedMembershipDAO, GovernanceController,
  MembershipTreasury, TreasurerModule, and FeeRouter.
*/

// ── Error catalog: signature → { title, hint } ──────────────────────────────

const ERROR_CATALOG = {
  // ─── Membership ────────────────────────────────────────────────
  "NotMember()": {
    title: "Not a Member",
    hint: "Your wallet is not associated with any guild membership. Ask an existing member to send you an invite.",
  },
  "AlreadyMember()": {
    title: "Already a Member",
    hint: "That address is already associated with an existing guild membership.",
  },
  "InvalidAddress()": {
    title: "Invalid Address",
    hint: "The address provided is invalid (zero address or otherwise unusable).",
  },
  "InvalidTarget()": {
    title: "Invalid Target",
    hint: "The target member doesn't exist, or this action can't be performed on them.",
  },
  "AlreadyInactive()": {
    title: "Already Inactive",
    hint: "This member is already deactivated.",
  },
  "MemberNotExpired()": {
    title: "Member Not Expired",
    hint: "This member's fee hasn't expired yet (including grace period). They can't be deactivated.",
  },
  "BootstrapAlreadyFinalized()": {
    title: "Bootstrap Finalized",
    hint: "The bootstrap phase has already ended. Members can only be added via invites now.",
  },
  "FundsNotAccepted()": {
    title: "Funds Not Accepted",
    hint: "This contract does not accept direct ETH transfers or NFTs.",
  },
  "NotController()": {
    title: "Not Authorized",
    hint: "Only the GovernanceController can perform this action.",
  },
  "NotFeeRouter()": {
    title: "Not Fee Router",
    hint: "Only the FeeRouter contract can record fee payments.",
  },

  // ─── Rank & Orders ─────────────────────────────────────────────
  "RankTooLow()": {
    title: "Rank Too Low",
    hint: "Your rank isn't high enough for this action. Higher ranks unlock more capabilities.",
  },
  "NotEnoughRank()": {
    title: "Insufficient Rank",
    hint: "You don't have enough rank to perform this action. You may have used all your invite/order/proposal slots for this epoch.",
  },
  "InvalidRank()": {
    title: "Invalid Rank",
    hint: "The specified rank doesn't make sense for this operation (e.g. promoting to a rank ≤ current).",
  },
  "InvalidPromotion()": {
    title: "Invalid Promotion",
    hint: "This promotion can't be issued. Remember: you can only promote to a rank at most 2 below yours, and it must be higher than the target's current rank.",
  },
  "InvalidDemotion()": {
    title: "Invalid Demotion",
    hint: "This demotion can't be issued. You must outrank the target by at least 2 ranks.",
  },
  "PendingActionExists()": {
    title: "Pending Action Exists",
    hint: "This member already has a pending order. Execute, block, or rescind it first before issuing a new one.",
  },
  "NoPendingAction()": {
    title: "No Pending Action",
    hint: "There's no pending order to act on — it may have already been executed, blocked, or rescinded.",
  },
  "OrderNotReady()": {
    title: "Order Not Ready",
    hint: "The timelock delay hasn't passed yet, or this order has already been executed.",
  },
  "OrderIsBlocked()": {
    title: "Order Blocked",
    hint: "This order has been blocked by a higher-ranking member or governance vote.",
  },
  "OrderWrongType()": {
    title: "Wrong Order Type",
    hint: "This action doesn't match the order type (e.g. trying to accept a demotion order).",
  },
  "OrderAlreadyRescinded()": {
    title: "Order Already Rescinded",
    hint: "This order was already rescinded by its issuer.",
  },
  "TooManyActiveOrders()": {
    title: "Too Many Active Orders",
    hint: "You've reached your order limit for your rank. Wait for existing orders to resolve.",
  },
  "VetoNotAllowed()": {
    title: "Veto Not Allowed",
    hint: "You need to outrank the order's issuer by at least 2 ranks to block it.",
  },

  // ─── Invites ───────────────────────────────────────────────────
  "InviteNotFound()": {
    title: "Invite Not Found",
    hint: "This invite ID doesn't exist.",
  },
  "InviteExpired()": {
    title: "Invite Expired",
    hint: "This invite has passed its expiry time and can no longer be accepted.",
  },
  "InviteAlreadyClaimed()": {
    title: "Invite Already Claimed",
    hint: "This invite has already been used by the invitee.",
  },
  "InviteAlreadyReclaimed()": {
    title: "Invite Already Reclaimed",
    hint: "This invite was already reclaimed by the issuer.",
  },
  "InviteNotYetExpired()": {
    title: "Invite Not Yet Expired",
    hint: "You can only reclaim an invite after it expires.",
  },
  "NotAuthorizedAuthority()": {
    title: "Not Authorized",
    hint: "You're not the authority address for this member.",
  },

  // ─── Proposals & Voting ────────────────────────────────────────
  "ProposalNotFound()": {
    title: "Proposal Not Found",
    hint: "This proposal ID doesn't exist.",
  },
  "ProposalNotActive()": {
    title: "Proposal Not Active",
    hint: "Voting hasn't started yet for this proposal.",
  },
  "ProposalEnded()": {
    title: "Voting Period Ended",
    hint: "The voting period for this proposal is over. It may need to be finalized.",
  },
  "ProposalAlreadyFinalized()": {
    title: "Already Finalized",
    hint: "This proposal has already been finalized.",
  },
  "AlreadyVoted()": {
    title: "Already Voted",
    hint: "You've already cast your vote on this proposal.",
  },
  "TooManyActiveProposals()": {
    title: "Too Many Active Proposals",
    hint: "You've reached your proposal limit for your rank. Wait for existing proposals to finalize.",
  },
  "VotingNotStarted()": {
    title: "Voting Not Started",
    hint: "The voting period hasn't begun for this proposal yet.",
  },

  // ─── Parameters ────────────────────────────────────────────────
  "ParameterOutOfBounds()": {
    title: "Parameter Out of Bounds",
    hint: "The value you specified is outside the allowed range for this parameter.",
  },
  "InvalidParameterValue()": {
    title: "Invalid Parameter Value",
    hint: "The parameter value or type is invalid for this proposal.",
  },

  // ─── Fee Payments ──────────────────────────────────────────────
  "FeeNotConfigured()": {
    title: "Fees Not Configured",
    hint: "Membership fees haven't been set up yet (base fee is zero).",
  },
  "PayoutTreasuryNotSet()": {
    title: "Payout Treasury Not Set",
    hint: "The DAO hasn't configured a payout treasury address for fee revenue.",
  },
  "IncorrectFeeAmount()": {
    title: "Incorrect Fee Amount",
    hint: "The ETH value sent doesn't match the required fee, or you sent ETH for an ERC-20 fee.",
  },
  "TransferFailed()": {
    title: "Transfer Failed",
    hint: "The payment transfer to the treasury failed.",
  },

  // ─── Treasury ──────────────────────────────────────────────────
  "TreasuryLocked()": {
    title: "Treasury Locked",
    hint: "The treasury is currently locked. A governance vote is needed to unlock it.",
  },
  "NotReady()": {
    title: "Not Ready",
    hint: "This proposal's execution delay hasn't passed yet.",
  },
  "ExecutionFailed()": {
    title: "Execution Failed",
    hint: "The proposal's on-chain action failed to execute.",
  },
  "CapExceeded()": {
    title: "Spending Cap Exceeded",
    hint: "This transfer would exceed the daily spending cap for this asset.",
  },
  "ActionDisabled()": {
    title: "Action Disabled",
    hint: "This type of treasury action is currently disabled.",
  },
  "ZeroAmount()": {
    title: "Zero Amount",
    hint: "The amount must be greater than zero.",
  },
  "CallTargetNotApproved()": {
    title: "Call Target Not Approved",
    hint: "The target contract address hasn't been approved for external calls.",
  },
  "NotModule()": {
    title: "Not Module",
    hint: "Only the TreasurerModule can call this function.",
  },
  "InvalidActionType()": {
    title: "Invalid Action Type",
    hint: "The specified action type isn't recognized.",
  },
  "ModuleAlreadySet()": {
    title: "Module Already Set",
    hint: "The TreasurerModule has already been configured.",
  },

  // ─── Treasurer Module ──────────────────────────────────────────
  "NotTreasurer()": {
    title: "Not a Treasurer",
    hint: "You're not assigned as a treasurer for this treasury.",
  },
  "NotTreasury()": {
    title: "Not Treasury",
    hint: "Only the MembershipTreasury can call this function.",
  },
  "TreasuryAlreadySet()": {
    title: "Treasury Already Set",
    hint: "The treasury address has already been configured.",
  },
  "TreasurerSpendingLimitExceeded()": {
    title: "Spending Limit Exceeded",
    hint: "This transfer would exceed your treasurer spending limit for this period.",
  },
  "TreasurerNotActive()": {
    title: "Treasurer Not Active",
    hint: "Your treasurer privileges are not currently active.",
  },
  "TreasurerAlreadyExists()": {
    title: "Treasurer Already Exists",
    hint: "This address is already registered as a treasurer.",
  },
  "InvalidPeriodDuration()": {
    title: "Invalid Period Duration",
    hint: "The spending period duration is invalid.",
  },
  "SpendingLimitTooHigh()": {
    title: "Spending Limit Too High",
    hint: "The requested spending limit exceeds the maximum allowed.",
  },
  "NoNFTAccess()": {
    title: "No NFT Access",
    hint: "You don't have access to manage this NFT.",
  },
  "NFTTransferLimitExceeded()": {
    title: "NFT Transfer Limit Exceeded",
    hint: "You've reached the NFT transfer limit for this period.",
  },
  "NFTAccessAlreadyGranted()": {
    title: "NFT Access Already Granted",
    hint: "This treasurer already has access to this NFT collection.",
  },
  "NFTAccessNotGranted()": {
    title: "NFT Access Not Granted",
    hint: "This treasurer doesn't have access to this NFT collection.",
  },
  "NFTNotOwned()": {
    title: "NFT Not Owned",
    hint: "The treasury doesn't own this NFT.",
  },
  "NotDeployer()": {
    title: "Not Deployer",
    hint: "Only the deployer can call this function.",
  },
  "TreasurerCallsDisabled()": {
    title: "Treasurer Calls Disabled",
    hint: "External contract calls by treasurers are currently disabled.",
  },
};

// ── Build selector → info lookup table ───────────────────────────────────────

const SELECTOR_MAP = {};
for (const [sig, info] of Object.entries(ERROR_CATALOG)) {
  const selector = keccak256(sig).slice(0, 10); // 0x + 4 bytes
  SELECTOR_MAP[selector] = { ...info, signature: sig };
}

// ── Common MetaMask / wallet errors ──────────────────────────────────────────

const WALLET_ERRORS = {
  4001: { title: "Transaction Rejected", hint: "You rejected the transaction in your wallet." },
  4100: { title: "Unauthorized", hint: "The requested account is not authorized." },
  4200: { title: "Unsupported Method", hint: "Your wallet doesn't support this method." },
  4900: { title: "Disconnected", hint: "Your wallet is disconnected from the chain." },
  4901: { title: "Chain Disconnected", hint: "Your wallet is disconnected from the requested chain." },
  "-32000": { title: "Insufficient Funds", hint: "Your account doesn't have enough ETH to cover the transaction cost." },
  "-32603": { title: "Internal Error", hint: "The RPC node returned an internal error. Try again." },
};

// ── Main decoder ─────────────────────────────────────────────────────────────

/**
 * Parse an ethers.js error and return a structured error object.
 *
 * @param {Error} err - The error thrown by ethers / MetaMask
 * @returns {{ title: string, hint: string, signature?: string, raw?: string }}
 */
export function decodeContractError(err) {
  if (!err) return { title: "Unknown Error", hint: "Something went wrong." };

  // 1. User rejected in wallet
  if (err.code === "ACTION_REJECTED" || err.code === 4001 || err?.info?.error?.code === 4001) {
    return WALLET_ERRORS[4001];
  }

  // 2. Try to extract revert data from the nested error
  const data = err.data
    ?? err?.info?.error?.data
    ?? err?.error?.data
    ?? err?.revert?.data
    ?? extractDataFromMessage(err.message);

  if (data && typeof data === "string" && data.startsWith("0x") && data.length >= 10) {
    const selector = data.slice(0, 10).toLowerCase();
    const known = SELECTOR_MAP[selector];
    if (known) return known;

    // Unknown selector — still give the user the hex
    return {
      title: "Contract Error",
      hint: `The contract reverted with an unrecognized error.`,
      raw: data,
    };
  }

  // 3. Check wallet error codes
  const code = err.code ?? err?.info?.error?.code ?? err?.error?.code;
  if (code && WALLET_ERRORS[String(code)]) {
    return WALLET_ERRORS[String(code)];
  }

  // 4. ethers reason string
  if (err.reason) {
    return {
      title: "Transaction Failed",
      hint: err.reason,
    };
  }

  // 5. Revert string (require("message"))
  if (err?.revert?.args?.[0]) {
    return {
      title: "Transaction Reverted",
      hint: err.revert.args[0],
    };
  }

  // 6. Fallback to message (trimmed)
  const msg = err.shortMessage ?? err.message ?? "Unknown error";
  // Try to clean up ethers verbose messages
  const clean = msg
    .replace(/\(action="[^"]*",\s*/, "(")
    .replace(/transaction=\{[^}]*\}[,\s]*/g, "")
    .replace(/receipt=\{[^}]*\}[,\s]*/g, "")
    .replace(/\(\s*\)/g, "")
    .trim();

  return {
    title: "Transaction Failed",
    hint: clean.length > 200 ? clean.slice(0, 200) + "…" : clean,
  };
}

/** Try to pull `data="0x…"` out of an error message string */
function extractDataFromMessage(msg) {
  if (!msg) return null;
  const match = msg.match(/data="(0x[0-9a-fA-F]+)"/);
  return match ? match[1] : null;
}
