const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Guild DAO System", function () {
  let dao, governance, treasury;
  let owner, member1, member2, outsider;

  beforeEach(async function () {
    [owner, member1, member2, outsider] = await ethers.getSigners();

    // Deploy DAO (owner becomes SSS member #1)
    const RankedMembershipDAO = await ethers.getContractFactory("RankedMembershipDAO");
    dao = await RankedMembershipDAO.deploy();
    await dao.waitForDeployment();

    // Deploy GovernanceController
    const GovernanceController = await ethers.getContractFactory("GovernanceController");
    governance = await GovernanceController.deploy(await dao.getAddress());
    await governance.waitForDeployment();

    // Wire controller
    await dao.setController(await governance.getAddress());

    // Deploy Treasury
    const MembershipTreasury = await ethers.getContractFactory("MembershipTreasury");
    treasury = await MembershipTreasury.deploy(await dao.getAddress());
    await treasury.waitForDeployment();
  });

  // -------------------------------------------------------
  // Deployment
  // -------------------------------------------------------
  describe("Deployment", function () {
    it("Should deploy all three contracts", async function () {
      expect(await dao.getAddress()).to.be.properAddress;
      expect(await governance.getAddress()).to.be.properAddress;
      expect(await treasury.getAddress()).to.be.properAddress;
    });

    it("Should link controller to DAO", async function () {
      expect(await dao.controller()).to.equal(await governance.getAddress());
    });

    it("Should link treasury to DAO", async function () {
      expect(await treasury.dao()).to.equal(await dao.getAddress());
    });

    it("Owner should be SSS member #1", async function () {
      const memberId = await dao.memberIdByAuthority(owner.address);
      expect(memberId).to.equal(1);

      const member = await dao.getMember(memberId);
      expect(member.exists).to.be.true;
      expect(member.rank).to.equal(9); // SSS
    });
  });

  // -------------------------------------------------------
  // Invite flow
  // -------------------------------------------------------
  describe("Invites", function () {
    it("SSS member can issue an invite", async function () {
      const tx = await governance.connect(owner).issueInvite(member1.address);
      const receipt = await tx.wait();

      // Check invite was created
      const invite = await governance.getInvite(1);
      expect(invite.exists).to.be.true;
      expect(invite.to).to.equal(member1.address);
    });

    it("Invited address can accept and become rank G", async function () {
      await governance.connect(owner).issueInvite(member1.address);
      await governance.connect(member1).acceptInvite(1);

      const memberId = await dao.memberIdByAuthority(member1.address);
      expect(memberId).to.equal(2);

      const member = await dao.getMember(memberId);
      expect(member.rank).to.equal(0); // G
    });

    it("Non-invited address cannot accept", async function () {
      await governance.connect(owner).issueInvite(member1.address);
      await expect(
        governance.connect(member2).acceptInvite(1)
      ).to.be.revertedWithCustomError(governance, "InvalidAddress");
    });
  });

  // -------------------------------------------------------
  // Treasury deposits
  // -------------------------------------------------------
  describe("Treasury Deposits", function () {
    it("Should accept ETH deposits", async function () {
      const amount = ethers.parseEther("1.0");

      await expect(
        owner.sendTransaction({
          to: await treasury.getAddress(),
          value: amount
        })
      ).to.emit(treasury, "DepositedETH")
        .withArgs(owner.address, amount);

      expect(await ethers.provider.getBalance(await treasury.getAddress()))
        .to.equal(amount);
    });

    it("Should accept ERC20 deposits", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const token = await MockERC20.deploy("Test Token", "TEST");
      await token.waitForDeployment();

      const amount = ethers.parseUnits("100", 18);
      await token.mint(owner.address, amount);
      await token.approve(await treasury.getAddress(), amount);

      await expect(
        treasury.depositERC20(await token.getAddress(), amount)
      ).to.emit(treasury, "DepositedERC20");
    });
  });

  // -------------------------------------------------------
  // Orders (timelocked)
  // -------------------------------------------------------
  describe("Timelocked Orders", function () {
    beforeEach(async function () {
      // Invite member1
      await governance.connect(owner).issueInvite(member1.address);
      await governance.connect(member1).acceptInvite(1);
    });

    it("SSS can issue a promotion grant for a G member", async function () {
      // SSS (rank 9) can promote up to rank 7 (9-2). Let's do F (rank 1).
      const memberId = await dao.memberIdByAuthority(member1.address);
      await expect(
        governance.connect(owner).issuePromotionGrant(memberId, 1) // F
      ).to.emit(governance, "OrderCreated");
    });

    it("Promotion grant can be accepted after delay", async function () {
      const memberId = await dao.memberIdByAuthority(member1.address);
      await governance.connect(owner).issuePromotionGrant(memberId, 1);

      // Fast forward past order delay (24h)
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");

      await governance.connect(member1).acceptPromotionGrant(1);

      const member = await dao.getMember(memberId);
      expect(member.rank).to.equal(1); // F
    });
  });

  // -------------------------------------------------------
  // Self authority change
  // -------------------------------------------------------
  describe("Self Authority Change", function () {
    it("Member can change their own authority", async function () {
      // Owner (member #1) changes authority to outsider address
      await dao.connect(owner).changeMyAuthority(outsider.address);

      const memberId = await dao.memberIdByAuthority(outsider.address);
      expect(memberId).to.equal(1);
      
      // Old authority is no longer linked
      expect(await dao.memberIdByAuthority(owner.address)).to.equal(0);
    });
  });
});
