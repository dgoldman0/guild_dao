const hre = require("hardhat");

async function main() {
  console.log("Deploying to network:", hre.network.name);

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Account balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // 1. Deploy RankedMembershipDAO
  console.log("\n📝 Deploying RankedMembershipDAO...");
  const RankedMembershipDAO = await hre.ethers.getContractFactory("RankedMembershipDAO");
  const dao = await RankedMembershipDAO.deploy();
  await dao.waitForDeployment();
  const daoAddress = await dao.getAddress();
  console.log("✅ RankedMembershipDAO deployed to:", daoAddress);

  // 2. Deploy GovernanceController
  console.log("\n⚙️  Deploying GovernanceController...");
  const GovernanceController = await hre.ethers.getContractFactory("GovernanceController");
  const governance = await GovernanceController.deploy(daoAddress);
  await governance.waitForDeployment();
  const governanceAddress = await governance.getAddress();
  console.log("✅ GovernanceController deployed to:", governanceAddress);

  // 3. Wire the controller into the DAO
  console.log("\n🔗 Setting controller on DAO...");
  let tx = await dao.setController(governanceAddress);
  await tx.wait();
  console.log("✅ Controller set to:", governanceAddress);

  // 4. Deploy TreasurerModule
  console.log("\n💼 Deploying TreasurerModule...");
  const TreasurerModule = await hre.ethers.getContractFactory("TreasurerModule");
  const treasurerModule = await TreasurerModule.deploy(daoAddress);
  await treasurerModule.waitForDeployment();
  const moduleAddress = await treasurerModule.getAddress();
  console.log("✅ TreasurerModule deployed to:", moduleAddress);

  // 5. Deploy MembershipTreasury
  console.log("\n💰 Deploying MembershipTreasury...");
  const MembershipTreasury = await hre.ethers.getContractFactory("MembershipTreasury");
  const treasury = await MembershipTreasury.deploy(daoAddress);
  await treasury.waitForDeployment();
  const treasuryAddress = await treasury.getAddress();
  console.log("✅ MembershipTreasury deployed to:", treasuryAddress);

  // 6. Wire Treasury ↔ Module
  console.log("\n🔗 Wiring Treasury ↔ TreasurerModule...");
  tx = await treasury.setTreasurerModule(moduleAddress);
  await tx.wait();
  tx = await treasurerModule.setTreasury(treasuryAddress);
  await tx.wait();
  console.log("✅ Module linked to Treasury");

  // 7. Wire DAO → Treasury (for fee payment calls)
  console.log("\n🔗 Setting FeeRouter on DAO...");
  const FeeRouter = await hre.ethers.getContractFactory("FeeRouter");
  const feeRouter = await FeeRouter.deploy(daoAddress);
  await feeRouter.waitForDeployment();
  const feeRouterAddress = await feeRouter.getAddress();
  console.log("✅ FeeRouter deployed to:", feeRouterAddress);

  tx = await dao.setFeeRouter(feeRouterAddress);
  await tx.wait();
  console.log("✅ DAO feeRouter set to:", feeRouterAddress);

  // 8. Set payout treasury (defaults to main treasury)
  console.log("\n💸 Setting payout treasury...");
  tx = await dao.setPayoutTreasury(treasuryAddress);
  await tx.wait();
  console.log("✅ Payout treasury set to:", treasuryAddress);

  console.log("\n🎉 Deployment complete!");
  console.log("======================================");
  console.log("RankedMembershipDAO:  ", daoAddress);
  console.log("GovernanceController: ", governanceAddress);
  console.log("TreasurerModule:      ", moduleAddress);
  console.log("MembershipTreasury:   ", treasuryAddress);
  console.log("FeeRouter:            ", feeRouterAddress);
  console.log("======================================");

  // Verify on live networks
  if (hre.network.name !== "hardhat" && hre.network.name !== "localhost") {
    console.log("\n⏳ Waiting for block confirmations...");
    await dao.deploymentTransaction().wait(5);
    await governance.deploymentTransaction().wait(5);
    await treasurerModule.deploymentTransaction().wait(5);
    await treasury.deploymentTransaction().wait(5);
    await feeRouter.deploymentTransaction().wait(5);

    console.log("\n🔍 Verifying contracts on Arbiscan...");

    for (const [name, addr, args] of [
      ["RankedMembershipDAO", daoAddress, []],
      ["GovernanceController", governanceAddress, [daoAddress]],
      ["TreasurerModule", moduleAddress, [daoAddress]],
      ["MembershipTreasury", treasuryAddress, [daoAddress]],
      ["FeeRouter", feeRouterAddress, [daoAddress]],
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
