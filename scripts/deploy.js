const hre = require("hardhat");

async function main() {
  console.log("Deploying to network:", hre.network.name);

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Account balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // 1. Deploy RankedMembershipDAO
  console.log("\n📝 Deploying RankedMembershipDAO…");
  const RankedMembershipDAO = await hre.ethers.getContractFactory("RankedMembershipDAO");
  const dao = await RankedMembershipDAO.deploy();
  await dao.waitForDeployment();
  const daoAddr = await dao.getAddress();
  console.log("✅ RankedMembershipDAO:", daoAddr);

  // 2. Deploy GuildController (sole DAO controller)
  console.log("\n🛡️  Deploying GuildController…");
  const GC = await hre.ethers.getContractFactory("GuildController");
  const guildCtrl = await GC.deploy(daoAddr);
  await guildCtrl.waitForDeployment();
  const guildCtrlAddr = await guildCtrl.getAddress();
  console.log("✅ GuildController:", guildCtrlAddr);

  // 3. Deploy OrderController
  console.log("\n⚔️  Deploying OrderController…");
  const ORD = await hre.ethers.getContractFactory("OrderController");
  const orderCtrl = await ORD.deploy(daoAddr, guildCtrlAddr);
  await orderCtrl.waitForDeployment();
  const orderCtrlAddr = await orderCtrl.getAddress();
  console.log("✅ OrderController:", orderCtrlAddr);

  // 4. Deploy ProposalController
  console.log("\n🗳️  Deploying ProposalController…");
  const PROP = await hre.ethers.getContractFactory("ProposalController");
  const proposalCtrl = await PROP.deploy(daoAddr, orderCtrlAddr, guildCtrlAddr);
  await proposalCtrl.waitForDeployment();
  const proposalCtrlAddr = await proposalCtrl.getAddress();
  console.log("✅ ProposalController:", proposalCtrlAddr);

  // 5. Deploy InviteController
  console.log("\n🎟️  Deploying InviteController…");
  const INV = await hre.ethers.getContractFactory("InviteController");
  const inviteCtrl = await INV.deploy(daoAddr);
  await inviteCtrl.waitForDeployment();
  const inviteCtrlAddr = await inviteCtrl.getAddress();
  console.log("✅ InviteController:", inviteCtrlAddr);

  // 6. Deploy TreasurerModule
  console.log("\n💼 Deploying TreasurerModule…");
  const MOD = await hre.ethers.getContractFactory("TreasurerModule");
  const mod = await MOD.deploy(daoAddr);
  await mod.waitForDeployment();
  const modAddr = await mod.getAddress();
  console.log("✅ TreasurerModule:", modAddr);

  // 7. Deploy MembershipTreasury
  console.log("\n💰 Deploying MembershipTreasury…");
  const TREAS = await hre.ethers.getContractFactory("MembershipTreasury");
  const treasury = await TREAS.deploy(daoAddr);
  await treasury.waitForDeployment();
  const treasuryAddr = await treasury.getAddress();
  console.log("✅ MembershipTreasury:", treasuryAddr);

  // 8. Deploy FeeRouter
  console.log("\n🔀 Deploying FeeRouter…");
  const FR = await hre.ethers.getContractFactory("FeeRouter");
  const feeRouter = await FR.deploy(daoAddr);
  await feeRouter.waitForDeployment();
  const feeRouterAddr = await feeRouter.getAddress();
  console.log("✅ FeeRouter:", feeRouterAddr);

  // ─── Wire contracts ────────────────────────────────────────

  console.log("\n🔗 Wiring contracts…");
  let tx;

  tx = await dao.setController(guildCtrlAddr);  await tx.wait();
  tx = await guildCtrl.setOrderController(orderCtrlAddr);  await tx.wait();
  tx = await guildCtrl.setProposalController(proposalCtrlAddr);  await tx.wait();
  tx = await orderCtrl.setProposalController(proposalCtrlAddr);  await tx.wait();
  tx = await dao.setInviteController(inviteCtrlAddr);  await tx.wait();
  tx = await treasury.setTreasurerModule(modAddr);  await tx.wait();
  tx = await mod.setTreasury(treasuryAddr);  await tx.wait();
  tx = await dao.setFeeRouter(feeRouterAddr);  await tx.wait();
  tx = await dao.setPayoutTreasury(treasuryAddr);  await tx.wait();
  console.log("✅ All wired");

  // ─── Summary ───────────────────────────────────────────────

  console.log("\n🎉 Deployment complete!");
  console.log("══════════════════════════════════════════════════════════");
  console.log("  RankedMembershipDAO:  ", daoAddr);
  console.log("  GuildController:      ", guildCtrlAddr);
  console.log("  OrderController:      ", orderCtrlAddr);
  console.log("  ProposalController:   ", proposalCtrlAddr);
  console.log("  InviteController:     ", inviteCtrlAddr);
  console.log("  TreasurerModule:      ", modAddr);
  console.log("  MembershipTreasury:   ", treasuryAddr);
  console.log("  FeeRouter:            ", feeRouterAddr);
  console.log("══════════════════════════════════════════════════════════");

  // ─── Verify on live networks ──────────────────────────────

  if (hre.network.name !== "hardhat" && hre.network.name !== "localhost") {
    console.log("\n⏳ Waiting for block confirmations…");
    await dao.deploymentTransaction().wait(5);
    await guildCtrl.deploymentTransaction().wait(5);
    await orderCtrl.deploymentTransaction().wait(5);
    await proposalCtrl.deploymentTransaction().wait(5);
    await inviteCtrl.deploymentTransaction().wait(5);
    await mod.deploymentTransaction().wait(5);
    await treasury.deploymentTransaction().wait(5);
    await feeRouter.deploymentTransaction().wait(5);

    console.log("\n🔍 Verifying contracts…");

    for (const [name, addr, args] of [
      ["RankedMembershipDAO", daoAddr, []],
      ["GuildController", guildCtrlAddr, [daoAddr]],
      ["OrderController", orderCtrlAddr, [daoAddr, guildCtrlAddr]],
      ["ProposalController", proposalCtrlAddr, [daoAddr, orderCtrlAddr, guildCtrlAddr]],
      ["InviteController", inviteCtrlAddr, [daoAddr]],
      ["TreasurerModule", modAddr, [daoAddr]],
      ["MembershipTreasury", treasuryAddr, [daoAddr]],
      ["FeeRouter", feeRouterAddr, [daoAddr]],
    ]) {
      try {
        await hre.run("verify:verify", { address: addr, constructorArguments: args });
        console.log(`✅ ${name} verified`);
      } catch (error) {
        console.log(`❌ ${name} verification failed:`, error.message);
      }
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
