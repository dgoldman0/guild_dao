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
  const tx = await dao.setController(governanceAddress);
  await tx.wait();
  console.log("✅ Controller set to:", governanceAddress);

  // 4. Deploy MembershipTreasury
  console.log("\n💰 Deploying MembershipTreasury...");
  const MembershipTreasury = await hre.ethers.getContractFactory("MembershipTreasury");
  const treasury = await MembershipTreasury.deploy(daoAddress);
  await treasury.waitForDeployment();
  const treasuryAddress = await treasury.getAddress();
  console.log("✅ MembershipTreasury deployed to:", treasuryAddress);

  console.log("\n🎉 Deployment complete!");
  console.log("==================================");
  console.log("RankedMembershipDAO:  ", daoAddress);
  console.log("GovernanceController: ", governanceAddress);
  console.log("MembershipTreasury:   ", treasuryAddress);
  console.log("==================================");

  // Verify on live networks
  if (hre.network.name !== "hardhat" && hre.network.name !== "localhost") {
    console.log("\n⏳ Waiting for block confirmations...");
    await dao.deploymentTransaction().wait(5);
    await governance.deploymentTransaction().wait(5);
    await treasury.deploymentTransaction().wait(5);

    console.log("\n🔍 Verifying contracts on Arbiscan...");

    for (const [name, addr, args] of [
      ["RankedMembershipDAO", daoAddress, []],
      ["GovernanceController", governanceAddress, [daoAddress]],
      ["MembershipTreasury", treasuryAddress, [daoAddress]],
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
