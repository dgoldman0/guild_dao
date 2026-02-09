const { expect } = require("chai");
const { ethers } = require("hardhat");

// Action-type constants matching ActionTypes.sol
const AT = {
  TRANSFER_ETH: 0,
  TRANSFER_ERC20: 1,
  CALL: 2,
  ADD_MEMBER_TREASURER: 3,
  SET_TREASURY_LOCKED: 20,
};

describe("Guild DAO System", function () {
  let dao, governance, treasurerModule, treasury;
  let owner, member1, member2, outsider;
  const coder = ethers.AbiCoder.defaultAbiCoder();

  beforeEach(async function () {
    [owner, member1, member2, outsider] = await ethers.getSigners();

    // 1. Deploy DAO
    const RankedMembershipDAO = await ethers.getContractFactory("RankedMembershipDAO");
    dao = await RankedMembershipDAO.deploy();
    await dao.waitForDeployment();

    // 2. Deploy GovernanceController
    const GovernanceController = await ethers.getContractFactory("GovernanceController");
    governance = await GovernanceController.deploy(await dao.getAddress());
    await governance.waitForDeployment();

    // 3. Wire controller
    await dao.setController(await governance.getAddress());

    // 4. Deploy TreasurerModule
    const TreasurerModule = await ethers.getContractFactory("TreasurerModule");
    treasurerModule = await TreasurerModule.deploy(await dao.getAddress());
    await treasurerModule.waitForDeployment();

    // 5. Deploy Treasury
    const MembershipTreasury = await ethers.getContractFactory("MembershipTreasury");
    treasury = await MembershipTreasury.deploy(await dao.getAddress());
    await treasury.waitForDeployment();

    // 6. Wire Treasury ↔ Module
    await treasury.setTreasurerModule(await treasurerModule.getAddress());
    await treasurerModule.setTreasury(await treasury.getAddress());
  });

  // ──────────────────────────────────────────────────────────
  // Deployment
  // ──────────────────────────────────────────────────────────
  describe("Deployment", function () {
    it("Should deploy all four contracts", async function () {
      expect(await dao.getAddress()).to.be.properAddress;
      expect(await governance.getAddress()).to.be.properAddress;
      expect(await treasurerModule.getAddress()).to.be.properAddress;
      expect(await treasury.getAddress()).to.be.properAddress;
    });

    it("Should link controller to DAO", async function () {
      expect(await dao.controller()).to.equal(await governance.getAddress());
    });

    it("Should link treasury to DAO", async function () {
      expect(await treasury.dao()).to.equal(await dao.getAddress());
    });

    it("Should link treasury ↔ module", async function () {
      expect(await treasury.treasurerModule()).to.equal(
        await treasurerModule.getAddress()
      );
      expect(await treasurerModule.treasury()).to.equal(
        await treasury.getAddress()
      );
    });

    it("Owner should be SSS member #1", async function () {
      const memberId = await dao.memberIdByAuthority(owner.address);
      expect(memberId).to.equal(1);

      const member = await dao.getMember(memberId);
      expect(member.exists).to.be.true;
      expect(member.rank).to.equal(9); // SSS
    });
  });

  // ──────────────────────────────────────────────────────────
  // Invite flow
  // ──────────────────────────────────────────────────────────
  describe("Invites", function () {
    it("SSS member can issue an invite", async function () {
      const tx = await governance.connect(owner).issueInvite(member1.address);
      await tx.wait();
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

  // ──────────────────────────────────────────────────────────
  // Treasury Deposits
  // ──────────────────────────────────────────────────────────
  describe("Treasury Deposits", function () {
    it("Should accept ETH deposits", async function () {
      const amount = ethers.parseEther("1.0");

      await expect(
        owner.sendTransaction({
          to: await treasury.getAddress(),
          value: amount,
        })
      )
        .to.emit(treasury, "DepositedETH")
        .withArgs(owner.address, amount);

      expect(
        await ethers.provider.getBalance(await treasury.getAddress())
      ).to.equal(amount);
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

  // ──────────────────────────────────────────────────────────
  // Generic Propose
  // ──────────────────────────────────────────────────────────
  describe("Generic Propose", function () {
    it("F+ member can create a TRANSFER_ETH proposal", async function () {
      // Invite member1 (G), then promote to F so they can propose
      await governance.connect(owner).issueInvite(member1.address);
      await governance.connect(member1).acceptInvite(1);
      const memberId = await dao.memberIdByAuthority(member1.address);

      // Promote to F via order
      await governance.connect(owner).issuePromotionGrant(memberId, 1); // F
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await governance.connect(member1).acceptPromotionGrant(1);

      // Propose ETH transfer
      const data = coder.encode(
        ["address", "uint256"],
        [outsider.address, ethers.parseEther("0.5")]
      );
      await expect(
        treasury.connect(member1).propose(AT.TRANSFER_ETH, data)
      ).to.emit(treasury, "ProposalCreated");
    });

    it("G member cannot propose", async function () {
      await governance.connect(owner).issueInvite(member1.address);
      await governance.connect(member1).acceptInvite(1);

      const data = coder.encode(
        ["address", "uint256"],
        [outsider.address, ethers.parseEther("0.5")]
      );
      await expect(
        treasury.connect(member1).propose(AT.TRANSFER_ETH, data)
      ).to.be.revertedWithCustomError(treasury, "NotMember");
    });

    it("Invalid action type reverts", async function () {
      const data = coder.encode(["bool"], [true]);
      await expect(
        treasury.connect(owner).propose(99, data)
      ).to.be.revertedWithCustomError(treasury, "InvalidActionType");
    });
  });

  // ──────────────────────────────────────────────────────────
  // Timelocked Orders
  // ──────────────────────────────────────────────────────────
  describe("Timelocked Orders", function () {
    beforeEach(async function () {
      await governance.connect(owner).issueInvite(member1.address);
      await governance.connect(member1).acceptInvite(1);
    });

    it("SSS can issue a promotion grant for a G member", async function () {
      const memberId = await dao.memberIdByAuthority(member1.address);
      await expect(
        governance.connect(owner).issuePromotionGrant(memberId, 1)
      ).to.emit(governance, "OrderCreated");
    });

    it("Promotion grant can be accepted after delay", async function () {
      const memberId = await dao.memberIdByAuthority(member1.address);
      await governance.connect(owner).issuePromotionGrant(memberId, 1);

      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");

      await governance.connect(member1).acceptPromotionGrant(1);
      const member = await dao.getMember(memberId);
      expect(member.rank).to.equal(1); // F
    });
  });

  // ──────────────────────────────────────────────────────────
  // Self Authority Change
  // ──────────────────────────────────────────────────────────
  describe("Self Authority Change", function () {
    it("Member can change their own authority", async function () {
      await dao.connect(owner).changeMyAuthority(outsider.address);
      expect(await dao.memberIdByAuthority(outsider.address)).to.equal(1);
      expect(await dao.memberIdByAuthority(owner.address)).to.equal(0);
    });
  });

  // ──────────────────────────────────────────────────────────
  // Bootstrap Finalization
  // ──────────────────────────────────────────────────────────
  describe("Bootstrap Finalization", function () {
    it("finalizeBootstrap renounces ownership", async function () {
      await dao.connect(owner).finalizeBootstrap();
      expect(await dao.owner()).to.equal(ethers.ZeroAddress);
    });
  });
});
