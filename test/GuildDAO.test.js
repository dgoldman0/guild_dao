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

// Rank enum indices matching Rank { G, F, E, D, C, B, A, S, SS, SSS }
const Rank = { G: 0, F: 1, E: 2, D: 3, C: 4, B: 5, A: 6, S: 7, SS: 8, SSS: 9 };

describe("Guild DAO System", function () {
  let dao, governance, treasurerModule, treasury;
  let owner, member1, member2, outsider, extra1, extra2, extra3;
  const coder = ethers.AbiCoder.defaultAbiCoder();

  // Helper: invite + accept → returns new memberId
  async function inviteAndAccept(inviter, inviteeWallet) {
    await governance.connect(inviter).issueInvite(inviteeWallet.address);
    const inviteId = (await governance.nextInviteId()) - 1n;
    await governance.connect(inviteeWallet).acceptInvite(inviteId);
    return await dao.memberIdByAuthority(inviteeWallet.address);
  }

  // Helper: promote via timelocked order (SSS issuer assumed)
  async function promoteViaOrder(issuer, targetId, newRank) {
    const tx = await governance.connect(issuer).issuePromotionGrant(targetId, newRank);
    const orderId = (await governance.nextOrderId()) - 1n;
    await ethers.provider.send("evm_increaseTime", [86401]);
    await ethers.provider.send("evm_mine");
    // get target authority to accept
    const member = await dao.getMember(targetId);
    const targetSigner = (await ethers.getSigners()).find(
      (s) => s.address === member.authority
    );
    await governance.connect(targetSigner).acceptPromotionGrant(orderId);
    return orderId;
  }

  beforeEach(async function () {
    [owner, member1, member2, outsider, extra1, extra2, extra3] =
      await ethers.getSigners();

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
      expect(member.rank).to.equal(Rank.SSS);
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
      expect(member.rank).to.equal(Rank.G);
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
      await governance.connect(owner).issuePromotionGrant(memberId, Rank.F);
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
        governance.connect(owner).issuePromotionGrant(memberId, Rank.F)
      ).to.emit(governance, "OrderCreated");
    });

    it("Promotion grant can be accepted after delay", async function () {
      const memberId = await dao.memberIdByAuthority(member1.address);
      await governance.connect(owner).issuePromotionGrant(memberId, Rank.F);

      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");

      await governance.connect(member1).acceptPromotionGrant(1);
      const member = await dao.getMember(memberId);
      expect(member.rank).to.equal(Rank.F);
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

  // ──────────────────────────────────────────────────────────
  // Stage 1: Order Limits
  // ──────────────────────────────────────────────────────────
  describe("Order Limits", function () {
    let m1Id, m2Id, m3Id;

    beforeEach(async function () {
      // Create 3 G-rank members
      m1Id = await inviteAndAccept(owner, member1);
      m2Id = await inviteAndAccept(owner, member2);
      m3Id = await inviteAndAccept(owner, extra1);
    });

    it("orderLimitOfRank returns correct values", async function () {
      expect(await dao.orderLimitOfRank(Rank.G)).to.equal(0);
      expect(await dao.orderLimitOfRank(Rank.F)).to.equal(0);
      expect(await dao.orderLimitOfRank(Rank.E)).to.equal(1);
      expect(await dao.orderLimitOfRank(Rank.D)).to.equal(2);
      expect(await dao.orderLimitOfRank(Rank.C)).to.equal(4);
      expect(await dao.orderLimitOfRank(Rank.SSS)).to.equal(128);
    });

    it("SSS member (128 slots) can issue many orders", async function () {
      // Owner is SSS, limit=128. Issue 3 promotion grants.
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      await governance.connect(owner).issuePromotionGrant(m2Id, Rank.F);
      await governance.connect(owner).issuePromotionGrant(m3Id, Rank.F);

      expect(await governance.activeOrdersOf(1)).to.equal(3); // owner = member #1
    });

    it("activeOrdersOf decrements when order is executed", async function () {
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      expect(await governance.activeOrdersOf(1)).to.equal(1);

      // Wait for delay then accept
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await governance.connect(member1).acceptPromotionGrant(1);

      expect(await governance.activeOrdersOf(1)).to.equal(0);
    });

    it("activeOrdersOf decrements when order is blocked", async function () {
      // Promote member1 to SS so they can block SSS orders
      // (blocker needs rank >= issuerRank + 2, but SSS=9, so nobody can block SSS)
      // Instead: promote member1 to E (rank 2), have them issue an order,
      // then have SSS block it (need blocker rank >= E+2 = D+, SSS qualifies)

      // First promote member1 to E
      await promoteViaOrder(owner, m1Id, Rank.E);

      // Now promote member2 to F so we have a target for member1's demotion
      // Actually E member can issue demotion on G (E >= G+2? E=2, G=0, 2 >= 0+2 ✓)
      // But first we need another G member as target — m2Id works
      // But m2 has no pending order. member1 (E) issues demotion on m2 (G):
      // issuerRank(E=2) >= targetRank(G=0)+2 ✓
      await governance.connect(member1).issueDemotionOrder(m2Id);
      expect(await governance.activeOrdersOf(m1Id)).to.equal(1);

      // Owner (SSS=9) blocks the order. SSS >= E(2)+2=4 ✓
      const orderId = (await governance.nextOrderId()) - 1n;
      await governance.connect(owner).blockOrder(orderId);

      expect(await governance.activeOrdersOf(m1Id)).to.equal(0);
    });

    it("E-rank member (limit=1) is blocked from second order", async function () {
      // Promote member1 to E
      await promoteViaOrder(owner, m1Id, Rank.E);

      // E can issue demotion on G: E(2) >= G(0)+2 ✓
      await governance.connect(member1).issueDemotionOrder(m2Id);
      expect(await governance.activeOrdersOf(m1Id)).to.equal(1);

      // Second order should revert — at limit
      await expect(
        governance.connect(member1).issueDemotionOrder(m3Id)
      ).to.be.revertedWithCustomError(governance, "TooManyActiveOrders");
    });

    it("Slot freed by execute allows another order", async function () {
      // Promote member1 to E
      await promoteViaOrder(owner, m1Id, Rank.E);

      // Issue demotion on m2
      await governance.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await governance.nextOrderId()) - 1n;

      // Execute it after delay
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await governance.connect(member1).executeOrder(orderId);

      expect(await governance.activeOrdersOf(m1Id)).to.equal(0);

      // Now a new order should succeed
      await governance.connect(member1).issueDemotionOrder(m3Id);
      expect(await governance.activeOrdersOf(m1Id)).to.equal(1);
    });

    it("G-rank and F-rank members cannot issue orders (limit=0)", async function () {
      // member1 is G, can't issue demotion (E+2 check fails anyway)
      // but let's also check that even if rank checks pass, order limit = 0 blocks it
      // Actually G and F can't issue orders because they can't meet the rank requirement
      // (need >= target + 2, minimum E). The limit check happens inside too.
      // Promote member1 to F (rank 1)
      await promoteViaOrder(owner, m1Id, Rank.F);

      // F trying to demote G: F(1) >= G(0)+2? 1>=2 NO → reverts with InvalidDemotion
      await expect(
        governance.connect(member1).issueDemotionOrder(m2Id)
      ).to.be.revertedWithCustomError(governance, "InvalidDemotion");
    });
  });

  // ──────────────────────────────────────────────────────────
  // Stage 1: Rescind Orders
  // ──────────────────────────────────────────────────────────
  describe("Rescind Orders", function () {
    let m1Id, m2Id, m3Id;

    beforeEach(async function () {
      m1Id = await inviteAndAccept(owner, member1);
      m2Id = await inviteAndAccept(owner, member2);
      m3Id = await inviteAndAccept(owner, extra1);
    });

    it("Issuer can rescind their own pending order", async function () {
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      const orderId = (await governance.nextOrderId()) - 1n;

      await expect(governance.connect(owner).rescindOrder(orderId))
        .to.emit(governance, "OrderRescinded")
        .withArgs(orderId, 1); // owner = member #1

      // Order should be marked blocked
      const order = await governance.getOrder(orderId);
      expect(order.blocked).to.be.true;

      // Active count decremented
      expect(await governance.activeOrdersOf(1)).to.equal(0);

      // Target slot freed
      expect(await governance.pendingOrderOfTarget(m1Id)).to.equal(0);
    });

    it("Non-issuer cannot rescind another member's order", async function () {
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      const orderId = (await governance.nextOrderId()) - 1n;

      // member1 is the target, not the issuer — should fail
      await expect(
        governance.connect(member1).rescindOrder(orderId)
      ).to.be.revertedWithCustomError(governance, "InvalidTarget");
    });

    it("Cannot rescind an already-executed order", async function () {
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      const orderId = (await governance.nextOrderId()) - 1n;

      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await governance.connect(member1).acceptPromotionGrant(orderId);

      await expect(
        governance.connect(owner).rescindOrder(orderId)
      ).to.be.revertedWithCustomError(governance, "OrderNotReady");
    });

    it("Cannot rescind an already-blocked order", async function () {
      // Promote member1 to E first so they can issue an order
      await promoteViaOrder(owner, m1Id, Rank.E);

      // member1 (E=2) issues demotion on m2 (G=0): 2 >= 0+2 ✓
      await governance.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await governance.nextOrderId()) - 1n;

      // Owner (SSS=9) blocks it: 9 >= 2+2 ✓
      await governance.connect(owner).blockOrder(orderId);

      await expect(
        governance.connect(member1).rescindOrder(orderId)
      ).to.be.revertedWithCustomError(governance, "OrderIsBlocked");
    });

    it("Rescind frees order slot for E-rank member", async function () {
      // Promote member1 to E (limit=1)
      await promoteViaOrder(owner, m1Id, Rank.E);

      // Issue order (uses the 1 slot)
      await governance.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await governance.nextOrderId()) - 1n;

      // At cap — second order fails
      await expect(
        governance.connect(member1).issueDemotionOrder(m3Id)
      ).to.be.revertedWithCustomError(governance, "TooManyActiveOrders");

      // Rescind the first order
      await governance.connect(member1).rescindOrder(orderId);

      // Now a new order succeeds
      await governance.connect(member1).issueDemotionOrder(m3Id);
      expect(await governance.activeOrdersOf(m1Id)).to.equal(1);
    });

    it("Outsider (non-member) cannot rescind", async function () {
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      const orderId = (await governance.nextOrderId()) - 1n;

      await expect(
        governance.connect(outsider).rescindOrder(orderId)
      ).to.be.revertedWithCustomError(governance, "NotMember");
    });
  });
});
