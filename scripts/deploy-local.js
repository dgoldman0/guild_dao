const hre = require("hardhat");

/*
  deploy-local.js  —  Full local deploy + populate for frontend testing.

  Boots a Hardhat-node world with:
    • All 6 contracts deployed & wired
    • User's real address bootstrapped as SSS
    • 8 additional members at various ranks (using Hardhat signers)
    • Fee config enabled (ETH, 0.01 ETH base, 7-day grace)
    • Treasury funded with 10 ETH
    • A few governance proposals (one active, one passed)
    • A pending promotion order
    • An issued invite
*/

const USER_ADDRESS = "0x2e1Ec8254928f7eB392224802d91D5277f96c1b2";

// Rank enum indices
const Rank = { G: 0, F: 1, E: 2, D: 3, C: 4, B: 5, A: 6, S: 7, SS: 8, SSS: 9 };

async function main() {
  const signers = await hre.ethers.getSigners();
  const deployer = signers[0]; // SSS member #1 (constructor)

  console.log("🏗  Deploying with:", deployer.address);

  // ─────────── 1. Deploy all contracts ───────────

  console.log("\n📝 Deploying RankedMembershipDAO…");
  const DAO = await hre.ethers.getContractFactory("RankedMembershipDAO");
  const dao = await DAO.deploy();
  await dao.waitForDeployment();
  const daoAddr = await dao.getAddress();
  console.log("   ✅", daoAddr);

  console.log("⚙️  Deploying GovernanceController…");
  const GOV = await hre.ethers.getContractFactory("GovernanceController");
  const gov = await GOV.deploy(daoAddr);
  await gov.waitForDeployment();
  const govAddr = await gov.getAddress();
  console.log("   ✅", govAddr);

  console.log("💼 Deploying TreasurerModule…");
  const MOD = await hre.ethers.getContractFactory("TreasurerModule");
  const mod = await MOD.deploy(daoAddr);
  await mod.waitForDeployment();
  const modAddr = await mod.getAddress();
  console.log("   ✅", modAddr);

  console.log("💰 Deploying MembershipTreasury…");
  const TREAS = await hre.ethers.getContractFactory("MembershipTreasury");
  const treasury = await TREAS.deploy(daoAddr);
  await treasury.waitForDeployment();
  const treasuryAddr = await treasury.getAddress();
  console.log("   ✅", treasuryAddr);

  console.log("🔀 Deploying FeeRouter…");
  const FR = await hre.ethers.getContractFactory("FeeRouter");
  const feeRouter = await FR.deploy(daoAddr);
  await feeRouter.waitForDeployment();
  const feeRouterAddr = await feeRouter.getAddress();
  console.log("   ✅", feeRouterAddr);

  console.log("🎟️  Deploying InviteController…");
  const INV = await hre.ethers.getContractFactory("InviteController");
  const inviteController = await INV.deploy(daoAddr);
  await inviteController.waitForDeployment();
  const inviteControllerAddr = await inviteController.getAddress();
  console.log("   ✅", inviteControllerAddr);

  // ─────────── 2. Wire contracts ───────────

  console.log("\n🔗 Wiring contracts…");
  await (await treasury.setTreasurerModule(modAddr)).wait();
  await (await mod.setTreasury(treasuryAddr)).wait();
  await (await dao.setController(govAddr)).wait();
  await (await dao.setFeeRouter(feeRouterAddr)).wait();
  await (await dao.setInviteController(inviteControllerAddr)).wait();
  await (await dao.setPayoutTreasury(treasuryAddr)).wait();
  console.log("   ✅ All wired");

  // ─────────── 3. Configure fees (owner can do this before finalize) ───────────

  console.log("\n💸 Configuring fees…");
  // ETH-based, 0.01 ETH base fee, 7-day grace
  await (await dao.setFeeToken(hre.ethers.ZeroAddress)).wait();
  await (await dao.setBaseFee(hre.ethers.parseEther("0.01"))).wait();
  await (await dao.setGracePeriod(7 * 24 * 3600)).wait(); // 7 days
  console.log("   ✅ ETH fees: 0.01 base, 7d grace");

  // ─────────── 4. Bootstrap members ───────────
  // deployer is already SSS (#1 via constructor)

  console.log("\n👥 Bootstrapping members…");

  // Member #2 — the real user, SSS
  await (await dao.bootstrapAddMember(USER_ADDRESS, Rank.SSS)).wait();
  console.log("   ✅ #2 USER (SSS):", USER_ADDRESS);

  // Members #3–#9 from hardhat signers at different ranks
  const bootstrapMembers = [
    { signer: signers[1],  rank: Rank.SS,  label: "SS"  },
    { signer: signers[2],  rank: Rank.S,   label: "S"   },
    { signer: signers[3],  rank: Rank.A,   label: "A"   },
    { signer: signers[4],  rank: Rank.B,   label: "B"   },
    { signer: signers[5],  rank: Rank.C,   label: "C"   },
    { signer: signers[6],  rank: Rank.D,   label: "D"   },
    { signer: signers[7],  rank: Rank.E,   label: "E"   },
    { signer: signers[8],  rank: Rank.F,   label: "F"   },
    { signer: signers[9],  rank: Rank.G,   label: "G"   },
  ];

  for (const m of bootstrapMembers) {
    await (await dao.bootstrapAddMember(m.signer.address, m.rank)).wait();
    console.log(`   ✅ #${await dao.memberIdByAuthority(m.signer.address)} ${m.label}: ${m.signer.address}`);
  }

  // ─────────── 5. Finalize bootstrap (renounces ownership) ───────────

  console.log("\n🔒 Finalizing bootstrap…");
  await (await dao.finalizeBootstrap()).wait();
  console.log("   ✅ Bootstrap finalized, ownership renounced");

  // ─────────── 6. Fund treasury with ETH ───────────

  console.log("\n💰 Funding treasury with 10 ETH…");
  await deployer.sendTransaction({ to: treasuryAddr, value: hre.ethers.parseEther("10") });
  console.log("   ✅ Treasury balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(treasuryAddr)), "ETH");

  // ─────────── 7. Create activity (proposals, orders, invites) ───────────

  console.log("\n📋 Creating test proposals & orders…");

  // SS member (#3, signer[1]) issues an invite to an external address
  const invAsSS = inviteController.connect(signers[1]);
  const tx1 = await invAsSS.issueInvite(signers[10].address);
  await tx1.wait();
  console.log("   ✅ Invite #1 issued by SS member to", signers[10].address);

  // S member (#4, signer[2]) creates a proposal to promote G member (#11) to F
  const govAsSS = gov.connect(signers[1]);
  const govAsS = gov.connect(signers[2]);
  const gMemberId = await dao.memberIdByAuthority(signers[9].address); // G member
  const tx2 = await govAsS.createProposalGrantRank(gMemberId, Rank.F);
  await tx2.wait();
  console.log("   ✅ Proposal #1: Promote G→F");

  // SS member casts yes vote on proposal #1
  await (await govAsSS.castVote(1, true)).wait();
  console.log("   ✅ SS voted YES on proposal #1");

  // S member also votes yes
  await (await govAsS.castVote(1, true)).wait();
  console.log("   ✅ S voted YES on proposal #1");

  // A member (#5, signer[3]) creates a proposal to change voting period to 3 days
  const govAsA = gov.connect(signers[3]);
  // ProposalType.ChangeVotingPeriod = 3
  const threeDays = 3 * 24 * 3600;
  const tx3 = await govAsA.createProposalChangeParameter(3, threeDays);
  await tx3.wait();
  console.log("   ✅ Proposal #2: Change voting period to 3 days");

  // SS member (#3, signer[1]) issues a promotion grant for D member (#8) → C
  // SS (rank 8) can promote up to rank 8-2 = 6 (A), D→C is fine
  const dMemberId = await dao.memberIdByAuthority(signers[6].address); // D member
  const tx4 = await govAsSS.issuePromotionGrant(dMemberId, Rank.C);
  await tx4.wait();
  console.log("   ✅ Order #1: SS promotes D→C");

  // S member (#4, signer[2]) issues demotion of F member (#10)
  // S (rank 7), F is rank 1. 7 >= 1+2 ✓
  const fMemberId = await dao.memberIdByAuthority(signers[8].address); // F member
  const tx5 = await govAsS.issueDemotionOrder(fMemberId);
  await tx5.wait();
  console.log("   ✅ Order #2: S demotes F→G");

  // ─────────── 8. Fund the user's address on local network ───────────

  console.log("\n💰 Funding user address with 100 ETH…");
  await deployer.sendTransaction({
    to: USER_ADDRESS,
    value: hre.ethers.parseEther("100"),
  });
  console.log("   ✅ User balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(USER_ADDRESS)), "ETH");

  // ─────────── Summary ───────────

  console.log("\n");
  console.log("══════════════════════════════════════════════════════════");
  console.log("  🎉  LOCAL DEPLOYMENT COMPLETE");
  console.log("══════════════════════════════════════════════════════════");
  console.log("  RankedMembershipDAO:  ", daoAddr);
  console.log("  GovernanceController: ", govAddr);
  console.log("  InviteController:     ", inviteControllerAddr);
  console.log("  TreasurerModule:      ", modAddr);
  console.log("  MembershipTreasury:   ", treasuryAddr);
  console.log("  FeeRouter:            ", feeRouterAddr);
  console.log("──────────────────────────────────────────────────────────");
  console.log("  Members bootstrapped: 11  (deployer SSS, user SSS, + 9 ranks)");
  console.log("  Treasury balance:     10 ETH");
  console.log("  Fee config:           0.01 ETH base × 2^rank, 7d grace");
  console.log("  Active proposals:     2");
  console.log("  Pending orders:       2");
  console.log("  User address:         ", USER_ADDRESS);
  console.log("  User ETH:             100 ETH");
  console.log("══════════════════════════════════════════════════════════");
  console.log("\n  → Add Hardhat network to MetaMask:  http://127.0.0.1:8545  chainId 31337");
  console.log("  → Then open the frontend at  http://localhost:5173\n");

  // ─────────── Output JSON for easy config patching ───────────
  const addresses = { dao: daoAddr, governance: govAddr, inviteController: inviteControllerAddr, treasury: treasuryAddr, feeRouter: feeRouterAddr };
  console.log("ADDRESSES_JSON=" + JSON.stringify(addresses));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
