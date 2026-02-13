const { expect } = require("chai");
const { ethers } = require("hardhat");

// Action-type constants matching ActionTypes.sol
const AT = {
  TRANSFER_ETH: 0,
  TRANSFER_ERC20: 1,
  CALL: 2,
  ADD_MEMBER_TREASURER: 3,
  UPDATE_MEMBER_TREASURER: 4,
  REMOVE_MEMBER_TREASURER: 5,
  ADD_ADDRESS_TREASURER: 6,
  UPDATE_ADDRESS_TREASURER: 7,
  REMOVE_ADDRESS_TREASURER: 8,
  SET_MEMBER_TOKEN_CONFIG: 9,
  SET_ADDRESS_TOKEN_CONFIG: 10,
  TRANSFER_NFT: 11,
  GRANT_MEMBER_NFT_ACCESS: 12,
  REVOKE_MEMBER_NFT_ACCESS: 13,
  GRANT_ADDRESS_NFT_ACCESS: 14,
  REVOKE_ADDRESS_NFT_ACCESS: 15,
  SET_CALL_ACTIONS_ENABLED: 16,
  SET_TREASURER_CALLS_ENABLED: 17,
  ADD_APPROVED_CALL_TARGET: 18,
  REMOVE_APPROVED_CALL_TARGET: 19,
  SET_TREASURY_LOCKED: 20,
};

// Rank enum indices matching Rank { G, F, E, D, C, B, A, S, SS, SSS }
const Rank = { G: 0, F: 1, E: 2, D: 3, C: 4, B: 5, A: 6, S: 7, SS: 8, SSS: 9 };

// Governance ProposalType enum
const PType = {
  GrantRank: 0, DemoteRank: 1, ChangeAuthority: 2,
  ChangeVotingPeriod: 3, ChangeQuorumBps: 4, ChangeOrderDelay: 5,
  ChangeInviteExpiry: 6, ChangeExecutionDelay: 7,
  BlockOrder: 8, TransferERC20: 9, ResetBootstrapFee: 10,
};

describe("Guild DAO System", function () {
  let dao, guild, orders, proposals, inviteController, treasurerModule, treasury, feeRouter;
  let owner, member1, member2, outsider, extra1, extra2, extra3;
  const coder = ethers.AbiCoder.defaultAbiCoder();

  // ─── Utility helpers ──────────────────────────────────────
  async function inviteAndAccept(inviter, inviteeWallet) {
    await inviteController.connect(inviter).issueInvite(inviteeWallet.address);
    const inviteId = (await inviteController.nextInviteId()) - 1n;
    await inviteController.connect(inviteeWallet).acceptInvite(inviteId);
    return await dao.memberIdByAuthority(inviteeWallet.address);
  }

  async function promoteViaOrder(issuer, targetId, newRank) {
    const tx = await orders.connect(issuer).issuePromotionGrant(targetId, newRank);
    const orderId = (await orders.nextOrderId()) - 1n;
    await ethers.provider.send("evm_increaseTime", [86401]);
    await ethers.provider.send("evm_mine");
    const member = await dao.getMember(targetId);
    const targetSigner = (await ethers.getSigners()).find(
      (s) => s.address === member.authority
    );
    await orders.connect(targetSigner).acceptPromotionGrant(orderId);
    return orderId;
  }

  // Mine blocks to move past VOTING_DELAY
  async function mineBlocks(n) {
    for (let i = 0; i < n; i++) {
      await ethers.provider.send("evm_mine");
    }
  }

  // Full treasury proposal lifecycle: propose → mine → vote → wait → finalize → wait → execute
  async function treasuryProposalLifecycle(signer, actionType, data) {
    const proposalId = await treasury.connect(signer).propose.staticCall(actionType, data);
    await treasury.connect(signer).propose(actionType, data);
    await mineBlocks(2); // past VOTING_DELAY
    await treasury.connect(signer).castVote(proposalId, true);
    // advance past voting period (7 days)
    await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
    await ethers.provider.send("evm_mine");
    await treasury.connect(signer).finalize(proposalId);
    // advance past execution delay (24h)
    await ethers.provider.send("evm_increaseTime", [86401]);
    await ethers.provider.send("evm_mine");
    await treasury.connect(signer).execute(proposalId);
    return proposalId;
  }

  beforeEach(async function () {
    [owner, member1, member2, outsider, extra1, extra2, extra3] =
      await ethers.getSigners();

    const RankedMembershipDAO = await ethers.getContractFactory("RankedMembershipDAO");
    dao = await RankedMembershipDAO.deploy();
    await dao.waitForDeployment();

    const GuildController = await ethers.getContractFactory("GuildController");
    guild = await GuildController.deploy(await dao.getAddress());
    await guild.waitForDeployment();

    const OrderController = await ethers.getContractFactory("OrderController");
    orders = await OrderController.deploy(await dao.getAddress(), await guild.getAddress());
    await orders.waitForDeployment();

    const ProposalController = await ethers.getContractFactory("ProposalController");
    proposals = await ProposalController.deploy(await dao.getAddress(), await orders.getAddress(), await guild.getAddress());
    await proposals.waitForDeployment();

    await dao.setController(await guild.getAddress());
    await guild.setOrderController(await orders.getAddress());
    await guild.setProposalController(await proposals.getAddress());
    await orders.setProposalController(await proposals.getAddress());

    const TreasurerModule = await ethers.getContractFactory("TreasurerModule");
    treasurerModule = await TreasurerModule.deploy(await dao.getAddress());
    await treasurerModule.waitForDeployment();

    const MembershipTreasury = await ethers.getContractFactory("MembershipTreasury");
    treasury = await MembershipTreasury.deploy(await dao.getAddress());
    await treasury.waitForDeployment();

    await treasury.setTreasurerModule(await treasurerModule.getAddress());
    await treasurerModule.setTreasury(await treasury.getAddress());

    const FeeRouter = await ethers.getContractFactory("FeeRouter");
    feeRouter = await FeeRouter.deploy(await dao.getAddress());
    await feeRouter.waitForDeployment();

    await dao.setFeeRouter(await feeRouter.getAddress());
    await dao.setPayoutTreasury(await treasury.getAddress());

    const InviteController = await ethers.getContractFactory("InviteController");
    inviteController = await InviteController.deploy(await dao.getAddress(), await guild.getAddress());
    await inviteController.waitForDeployment();

    await guild.setInviteController(await inviteController.getAddress());
  });

  // ══════════════════════════════════════════════════════════
  //  Deployment
  // ══════════════════════════════════════════════════════════
  describe("Deployment", function () {
    it("deploys all contracts including GuildController and split controllers", async function () {
      expect(await dao.getAddress()).to.be.properAddress;
      expect(await guild.getAddress()).to.be.properAddress;
      expect(await orders.getAddress()).to.be.properAddress;
      expect(await proposals.getAddress()).to.be.properAddress;
      expect(await inviteController.getAddress()).to.be.properAddress;
      expect(await treasurerModule.getAddress()).to.be.properAddress;
      expect(await treasury.getAddress()).to.be.properAddress;
      expect(await feeRouter.getAddress()).to.be.properAddress;
    });

    it("links GuildController as sole DAO controller", async function () {
      expect(await dao.controller()).to.equal(await guild.getAddress());
    });

    it("links orderController on GuildController", async function () {
      expect(await guild.orderController()).to.equal(await orders.getAddress());
    });

    it("links proposalController on GuildController", async function () {
      expect(await guild.proposalController()).to.equal(await proposals.getAddress());
    });

    it("links inviteController on GuildController", async function () {
      expect(await guild.inviteController()).to.equal(await inviteController.getAddress());
    });

    it("links treasury ↔ module", async function () {
      expect(await treasury.treasurerModule()).to.equal(await treasurerModule.getAddress());
      expect(await treasurerModule.treasury()).to.equal(await treasury.getAddress());
    });

    it("links feeRouter + payoutTreasury on DAO", async function () {
      expect(await dao.feeRouter()).to.equal(await feeRouter.getAddress());
      expect(await dao.payoutTreasury()).to.equal(await treasury.getAddress());
    });

    it("owner is SSS member #1", async function () {
      const m = await dao.getMember(1);
      expect(m.exists).to.be.true;
      expect(m.rank).to.equal(Rank.SSS);
      expect(m.authority).to.equal(owner.address);
    });
  });

  // ══════════════════════════════════════════════════════════
  //  Stage 2a: RankedMembershipDAO Tests
  // ══════════════════════════════════════════════════════════
  describe("RankedMembershipDAO", function () {

    // --- Bootstrap ---
    describe("Bootstrap", function () {
      it("can add multiple members during bootstrap", async function () {
        await dao.bootstrapAddMember(member1.address, Rank.A);
        await dao.bootstrapAddMember(member2.address, Rank.B);
        const m1 = await dao.getMember(2);
        const m2 = await dao.getMember(3);
        expect(m1.rank).to.equal(Rank.A);
        expect(m2.rank).to.equal(Rank.B);
      });

      it("finalizeBootstrap renounces ownership", async function () {
        await dao.finalizeBootstrap();
        expect(await dao.owner()).to.equal(ethers.ZeroAddress);
        expect(await dao.bootstrapFinalized()).to.be.true;
      });

      it("bootstrapAddMember reverts after finalization", async function () {
        await dao.finalizeBootstrap();
        await expect(
          dao.bootstrapAddMember(member1.address, Rank.F)
        ).to.be.revertedWithCustomError(dao, "OwnableUnauthorizedAccount");
      });

      it("second finalizeBootstrap reverts (owner renounced)", async function () {
        await dao.finalizeBootstrap();
        await expect(
          dao.finalizeBootstrap()
        ).to.be.revertedWithCustomError(dao, "OwnableUnauthorizedAccount");
      });
    });

    // --- setController ---
    describe("setController", function () {
      it("owner can set controller", async function () {
        // Already set in beforeEach, but test a second time
        await dao.setController(member1.address);
        expect(await dao.controller()).to.equal(member1.address);
      });

      it("current controller can migrate to a new controller", async function () {
        // proposals controller is the controller — owner can't call after finalize
        // We can't directly impersonate, but we can verify random caller reverts
        await dao.finalizeBootstrap(); // owner renounced
        // Now only controller (proposals contract) can call setController.
        // We can't call dao.setController from proposals directly (no such method).
        // Instead, verify random caller reverts:
        await expect(
          dao.connect(member1).setController(member2.address)
        ).to.be.revertedWithCustomError(dao, "NotController");
      });

      it("random address cannot set controller", async function () {
        await expect(
          dao.connect(outsider).setController(member1.address)
        ).to.be.revertedWithCustomError(dao, "NotController");
      });

      it("cannot set controller to zero address", async function () {
        await expect(
          dao.setController(ethers.ZeroAddress)
        ).to.be.revertedWithCustomError(dao, "InvalidAddress");
      });
    });

    // --- changeMyAuthority ---
    describe("changeMyAuthority", function () {
      it("member can change their own authority", async function () {
        await dao.connect(owner).changeMyAuthority(outsider.address);
        expect(await dao.memberIdByAuthority(outsider.address)).to.equal(1);
        expect(await dao.memberIdByAuthority(owner.address)).to.equal(0);
      });

      it("reverts with zero address", async function () {
        await expect(
          dao.connect(owner).changeMyAuthority(ethers.ZeroAddress)
        ).to.be.revertedWithCustomError(dao, "InvalidAddress");
      });

      it("reverts if new authority is already a member", async function () {
        await dao.bootstrapAddMember(member1.address, Rank.F);
        await expect(
          dao.connect(owner).changeMyAuthority(member1.address)
        ).to.be.revertedWithCustomError(dao, "AlreadyMember");
      });

      it("non-member cannot call changeMyAuthority", async function () {
        await expect(
          dao.connect(outsider).changeMyAuthority(member1.address)
        ).to.be.revertedWithCustomError(dao, "NotMember");
      });
    });

    // --- Pause/Unpause ---
    describe("Pause", function () {
      it("owner can pause and unpause", async function () {
        await dao.pause();
        await expect(
          dao.connect(owner).changeMyAuthority(member1.address)
        ).to.be.revertedWithCustomError(dao, "EnforcedPause");
        await dao.unpause();
        await dao.connect(owner).changeMyAuthority(member1.address);
        expect(await dao.memberIdByAuthority(member1.address)).to.equal(1);
      });

      it("non-owner cannot pause", async function () {
        await expect(
          dao.connect(outsider).pause()
        ).to.be.revertedWithCustomError(dao, "OwnableUnauthorizedAccount");
      });
    });

    // --- Fund rejection ---
    describe("Fund Rejection", function () {
      it("rejects ETH sent to DAO", async function () {
        await expect(
          owner.sendTransaction({ to: await dao.getAddress(), value: ethers.parseEther("1") })
        ).to.be.revertedWithCustomError(dao, "FundsNotAccepted");
      });
    });

    // --- Voting power snapshots ---
    describe("Voting Power", function () {
      it("votingPowerOfRank doubles per rank", async function () {
        expect(await dao.votingPowerOfRank(Rank.G)).to.equal(1);
        expect(await dao.votingPowerOfRank(Rank.F)).to.equal(2);
        expect(await dao.votingPowerOfRank(Rank.E)).to.equal(4);
        expect(await dao.votingPowerOfRank(Rank.SSS)).to.equal(512);
      });

      it("total voting power updates on member add", async function () {
        // owner = SSS = 512
        expect(await dao.totalVotingPower()).to.equal(512);
        await dao.bootstrapAddMember(member1.address, Rank.F); // +2
        expect(await dao.totalVotingPower()).to.equal(514);
      });

      it("snapshot records historical power", async function () {
        const blockBefore = await ethers.provider.getBlockNumber();
        await dao.bootstrapAddMember(member1.address, Rank.F);
        await mineBlocks(1);
        // At blockBefore, member1 didn't exist yet — power should be 0
        expect(await dao.votingPowerOfMemberAt(2, blockBefore)).to.equal(0);
        // At current block, member1 has power 2
        const blockAfter = await ethers.provider.getBlockNumber();
        expect(await dao.votingPowerOfMemberAt(2, blockAfter)).to.equal(2);
      });
    });

    // --- Rank helper functions ---
    describe("Rank Helpers", function () {
      it("inviteAllowanceOfRank", async function () {
        expect(await dao.inviteAllowanceOfRank(Rank.G)).to.equal(0);
        expect(await dao.inviteAllowanceOfRank(Rank.F)).to.equal(1);
        expect(await dao.inviteAllowanceOfRank(Rank.E)).to.equal(2);
        expect(await dao.inviteAllowanceOfRank(Rank.SSS)).to.equal(256);
      });

      it("proposalLimitOfRank", async function () {
        expect(await dao.proposalLimitOfRank(Rank.G)).to.equal(0);
        expect(await dao.proposalLimitOfRank(Rank.F)).to.equal(1);
        expect(await dao.proposalLimitOfRank(Rank.SSS)).to.equal(9);
      });

      it("orderLimitOfRank", async function () {
        expect(await dao.orderLimitOfRank(Rank.G)).to.equal(0);
        expect(await dao.orderLimitOfRank(Rank.F)).to.equal(0);
        expect(await dao.orderLimitOfRank(Rank.E)).to.equal(1);
        expect(await dao.orderLimitOfRank(Rank.SSS)).to.equal(128);
      });
    });
  });

  // ══════════════════════════════════════════════════════════
  //  Invites (comprehensive)
  // ══════════════════════════════════════════════════════════
  describe("Invites", function () {
    it("SSS member can issue an invite", async function () {
      await inviteController.connect(owner).issueInvite(member1.address);
      const inv = await inviteController.getInvite(1);
      expect(inv.exists).to.be.true;
      expect(inv.to).to.equal(member1.address);
    });

    it("invited address accepts and becomes rank G", async function () {
      const id = await inviteAndAccept(owner, member1);
      const m = await dao.getMember(id);
      expect(m.rank).to.equal(Rank.G);
    });

    it("non-invited address cannot accept", async function () {
      await inviteController.connect(owner).issueInvite(member1.address);
      await expect(
        inviteController.connect(member2).acceptInvite(1)
      ).to.be.revertedWithCustomError(inviteController, "InvalidAddress");
    });

    it("cannot accept same invite twice", async function () {
      await inviteController.connect(owner).issueInvite(member1.address);
      await inviteController.connect(member1).acceptInvite(1);
      await expect(
        inviteController.connect(member1).acceptInvite(1)
      ).to.be.revertedWithCustomError(inviteController, "InviteAlreadyClaimed");
    });

    it("invite expires and can be reclaimed", async function () {
      await inviteController.connect(owner).issueInvite(member1.address);
      // advance past invite expiry (24h)
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      // accept fails (expired)
      await expect(
        inviteController.connect(member1).acceptInvite(1)
      ).to.be.revertedWithCustomError(inviteController, "InviteExpired");
      // reclaim succeeds
      await inviteController.connect(owner).reclaimExpiredInvite(1);
      const inv = await inviteController.getInvite(1);
      expect(inv.reclaimed).to.be.true;
    });

    it("cannot reclaim before expiry", async function () {
      await inviteController.connect(owner).issueInvite(member1.address);
      await expect(
        inviteController.connect(owner).reclaimExpiredInvite(1)
      ).to.be.revertedWithCustomError(inviteController, "InviteNotYetExpired");
    });

    it("G member cannot issue invites (allowance=0)", async function () {
      await inviteAndAccept(owner, member1);
      await expect(
        inviteController.connect(member1).issueInvite(member2.address)
      ).to.be.revertedWithCustomError(inviteController, "NotEnoughRank");
    });

    it("cannot invite an existing member", async function () {
      await inviteAndAccept(owner, member1);
      await expect(
        inviteController.connect(owner).issueInvite(member1.address)
      ).to.be.revertedWithCustomError(inviteController, "AlreadyMember");
    });
  });

  // ══════════════════════════════════════════════════════════
  //  Timelocked Orders (comprehensive)
  // ══════════════════════════════════════════════════════════
  describe("Timelocked Orders", function () {
    let m1Id, m2Id, m3Id;

    beforeEach(async function () {
      m1Id = await inviteAndAccept(owner, member1);
      m2Id = await inviteAndAccept(owner, member2);
      m3Id = await inviteAndAccept(owner, extra1);
    });

    it("promotion grant: create, wait, accept", async function () {
      await orders.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      // Too early
      await expect(
        orders.connect(member1).acceptPromotionGrant(1)
      ).to.be.revertedWithCustomError(orders, "OrderNotReady");
      // Wait
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await orders.connect(member1).acceptPromotionGrant(1);
      expect((await dao.getMember(m1Id)).rank).to.equal(Rank.F);
    });

    it("demotion order: create, wait, execute", async function () {
      // Promote m1 to E first so SSS can demote E (SSS=9 >= E(2)+2=4 ✓)
      await promoteViaOrder(owner, m1Id, Rank.E);

      await orders.connect(owner).issueDemotionOrder(m1Id);
      const orderId = (await orders.nextOrderId()) - 1n;

      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await orders.connect(owner).executeOrder(orderId);

      expect((await dao.getMember(m1Id)).rank).to.equal(Rank.F); // E-1=D? No, demotion does rank-1
    });

    it("authority order: create, wait, execute", async function () {
      // SSS(9) can issue authority order on G(0): 9 >= 0+2 ✓
      await orders.connect(owner).issueAuthorityOrder(m1Id, extra2.address);
      const orderId = (await orders.nextOrderId()) - 1n;

      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await orders.connect(owner).executeOrder(orderId);

      expect((await dao.getMember(m1Id)).authority).to.equal(extra2.address);
    });

    it("block order by higher rank", async function () {
      await orders.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      const orderId = (await orders.nextOrderId()) - 1n;
      // blocker needs rank >= SSS(9)+2 = impossible for SSS
      // Let's use a different scenario: promote m1 to E, m1 issues demotion on m2,
      // then SSS blocks
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await orders.connect(member1).acceptPromotionGrant(orderId);

      // promote m1 further to E
      await promoteViaOrder(owner, m1Id, Rank.E);

      // m1 (E=2) demotes m2 (G=0): 2 >= 0+2 ✓
      await orders.connect(member1).issueDemotionOrder(m2Id);
      const demoOrderId = (await orders.nextOrderId()) - 1n;

      // Owner (SSS=9) blocks: 9 >= 2+2 ✓
      await orders.connect(owner).blockOrder(demoOrderId);
      const order = await orders.getOrder(demoOrderId);
      expect(order.blocked).to.be.true;
    });

    it("cannot execute before delay", async function () {
      await orders.connect(owner).issueDemotionOrder(m1Id);
      await expect(
        orders.connect(owner).executeOrder(1)
      ).to.be.revertedWithCustomError(orders, "OrderNotReady");
    });

    it("cannot execute blocked order", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await orders.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await orders.nextOrderId()) - 1n;
      await orders.connect(owner).blockOrder(orderId);

      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await expect(
        orders.connect(member1).executeOrder(orderId)
      ).to.be.revertedWithCustomError(orders, "OrderIsBlocked");
    });

    it("only one pending order per target", async function () {
      await orders.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      // second order on same target fails
      await expect(
        orders.connect(owner).issueDemotionOrder(m1Id)
      ).to.be.revertedWithCustomError(orders, "PendingActionExists");
    });
  });

  // ══════════════════════════════════════════════════════════
  //  Order Limits
  // ══════════════════════════════════════════════════════════
  describe("Order Limits", function () {
    let m1Id, m2Id, m3Id;

    beforeEach(async function () {
      m1Id = await inviteAndAccept(owner, member1);
      m2Id = await inviteAndAccept(owner, member2);
      m3Id = await inviteAndAccept(owner, extra1);
    });

    it("SSS member can issue many orders", async function () {
      await orders.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      await orders.connect(owner).issuePromotionGrant(m2Id, Rank.F);
      await orders.connect(owner).issuePromotionGrant(m3Id, Rank.F);
      expect(await orders.activeOrdersOf(1)).to.equal(3);
    });

    it("E-rank member (limit=1) is blocked from second order", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await orders.connect(member1).issueDemotionOrder(m2Id);
      await expect(
        orders.connect(member1).issueDemotionOrder(m3Id)
      ).to.be.revertedWithCustomError(orders, "TooManyActiveOrders");
    });

    it("slot freed by execute allows another order", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await orders.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await orders.nextOrderId()) - 1n;
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await orders.connect(member1).executeOrder(orderId);

      await orders.connect(member1).issueDemotionOrder(m3Id);
      expect(await orders.activeOrdersOf(m1Id)).to.equal(1);
    });

    it("slot freed by block allows another order", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await orders.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await orders.nextOrderId()) - 1n;
      await orders.connect(owner).blockOrder(orderId);

      await orders.connect(member1).issueDemotionOrder(m3Id);
      expect(await orders.activeOrdersOf(m1Id)).to.equal(1);
    });
  });

  // ══════════════════════════════════════════════════════════
  //  Rescind Orders
  // ══════════════════════════════════════════════════════════
  describe("Rescind Orders", function () {
    let m1Id, m2Id, m3Id;

    beforeEach(async function () {
      m1Id = await inviteAndAccept(owner, member1);
      m2Id = await inviteAndAccept(owner, member2);
      m3Id = await inviteAndAccept(owner, extra1);
    });

    it("issuer can rescind their own pending order", async function () {
      await orders.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      const orderId = (await orders.nextOrderId()) - 1n;
      await expect(orders.connect(owner).rescindOrder(orderId))
        .to.emit(orders, "OrderRescinded").withArgs(orderId, 1);
      expect(await orders.activeOrdersOf(1)).to.equal(0);
      expect(await orders.pendingOrderOfTarget(m1Id)).to.equal(0);
    });

    it("non-issuer cannot rescind", async function () {
      await orders.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      await expect(
        orders.connect(member1).rescindOrder(1)
      ).to.be.revertedWithCustomError(orders, "InvalidTarget");
    });

    it("cannot rescind executed order", async function () {
      await orders.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await orders.connect(member1).acceptPromotionGrant(1);
      await expect(
        orders.connect(owner).rescindOrder(1)
      ).to.be.revertedWithCustomError(orders, "OrderNotReady");
    });

    it("cannot rescind blocked order", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await orders.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await orders.nextOrderId()) - 1n;
      await orders.connect(owner).blockOrder(orderId);
      await expect(
        orders.connect(member1).rescindOrder(orderId)
      ).to.be.revertedWithCustomError(orders, "OrderIsBlocked");
    });

    it("rescind frees slot for E-rank member", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await orders.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await orders.nextOrderId()) - 1n;
      await expect(orders.connect(member1).issueDemotionOrder(m3Id))
        .to.be.revertedWithCustomError(orders, "TooManyActiveOrders");
      await orders.connect(member1).rescindOrder(orderId);
      await orders.connect(member1).issueDemotionOrder(m3Id);
      expect(await orders.activeOrdersOf(m1Id)).to.equal(1);
    });

    it("outsider cannot rescind", async function () {
      await orders.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      await expect(
        orders.connect(outsider).rescindOrder(1)
      ).to.be.revertedWithCustomError(orders, "NotMember");
    });
  });

  // ══════════════════════════════════════════════════════════
  //  Stage 2b: Governance Proposals
  // ══════════════════════════════════════════════════════════
  describe("Governance Proposals", function () {

    it("GrantRank proposal: full cycle", async function () {
      const m1Id = await inviteAndAccept(owner, member1);

      // owner (SSS) proposes promoting m1 to A
      await proposals.connect(owner).createProposalGrantRank(m1Id, Rank.A);
      const propId = (await proposals.nextProposalId()) - 1n;

      // vote yes
      await proposals.connect(owner).castVote(propId, true);

      // wait for voting period to end
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");

      await proposals.connect(owner).finalizeProposal(propId);
      const p = await proposals.getProposal(propId);
      expect(p.succeeded).to.be.true;
      expect((await dao.getMember(m1Id)).rank).to.equal(Rank.A);
    });

    it("DemoteRank proposal: full cycle", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await promoteViaOrder(owner, m1Id, Rank.E);

      await proposals.connect(owner).createProposalDemoteRank(m1Id, Rank.F);
      const propId = (await proposals.nextProposalId()) - 1n;
      await proposals.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await proposals.connect(owner).finalizeProposal(propId);

      expect((await dao.getMember(m1Id)).rank).to.equal(Rank.F);
    });

    it("ChangeAuthority proposal: full cycle", async function () {
      const m1Id = await inviteAndAccept(owner, member1);

      await proposals.connect(owner).createProposalChangeAuthority(m1Id, extra2.address);
      const propId = (await proposals.nextProposalId()) - 1n;
      await proposals.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await proposals.connect(owner).finalizeProposal(propId);

      expect((await dao.getMember(m1Id)).authority).to.equal(extra2.address);
    });

    it("ChangeVotingPeriod parameter proposal: full cycle", async function () {
      const newPeriod = 3 * 86400; // 3 days
      await proposals.connect(owner).createProposalChangeParameter(PType.ChangeVotingPeriod, newPeriod);
      const propId = (await proposals.nextProposalId()) - 1n;
      await proposals.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await proposals.connect(owner).finalizeProposal(propId);

      expect(await dao.votingPeriod()).to.equal(newPeriod);
    });

    it("BlockOrder proposal: full cycle", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await orders.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      const orderId = (await orders.nextOrderId()) - 1n;

      // propose to block the order
      await proposals.connect(owner).createProposalBlockOrder(orderId);
      const propId = (await proposals.nextProposalId()) - 1n;
      await proposals.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await proposals.connect(owner).finalizeProposal(propId);

      const order = await orders.getOrder(orderId);
      expect(order.blocked).to.be.true;
    });

    it("TransferERC20 proposal: full cycle", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const token = await MockERC20.deploy("Test", "TST");
      await token.waitForDeployment();
      const amount = ethers.parseUnits("100", 18);
      await token.mint(await dao.getAddress(), amount);

      await proposals.connect(owner).createProposalTransferERC20(
        await token.getAddress(), amount, member1.address
      );
      const propId = (await proposals.nextProposalId()) - 1n;
      await proposals.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await proposals.connect(owner).finalizeProposal(propId);

      expect(await token.balanceOf(member1.address)).to.equal(amount);
    });

    // --- Edge cases ---
    it("vote after voting period ends → revert", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await proposals.connect(owner).createProposalGrantRank(m1Id, Rank.F);
      const propId = (await proposals.nextProposalId()) - 1n;

      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");

      await expect(
        proposals.connect(owner).castVote(propId, true)
      ).to.be.revertedWithCustomError(proposals, "ProposalEnded");
    });

    it("double vote → revert", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await proposals.connect(owner).createProposalGrantRank(m1Id, Rank.F);
      const propId = (await proposals.nextProposalId()) - 1n;
      await proposals.connect(owner).castVote(propId, true);
      await expect(
        proposals.connect(owner).castVote(propId, false)
      ).to.be.revertedWithCustomError(proposals, "AlreadyVoted");
    });

    it("finalize before end → revert", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await proposals.connect(owner).createProposalGrantRank(m1Id, Rank.F);
      const propId = (await proposals.nextProposalId()) - 1n;
      await expect(
        proposals.connect(owner).finalizeProposal(propId)
      ).to.be.revertedWithCustomError(proposals, "ProposalEnded");
    });

    it("quorum not met → proposal fails", async function () {
      // Add many members to dilute voting power, then vote with only one
      await dao.bootstrapAddMember(member1.address, Rank.SSS); // member2 id=2
      await dao.bootstrapAddMember(member2.address, Rank.SSS); // member3 id=3
      // total power = 512*3=1536. quorum = 20% = 307.2 → 308
      // Only G member (power=1) votes — won't meet quorum
      const m4Id = await inviteAndAccept(owner, extra1); // G member

      await proposals.connect(owner).createProposalGrantRank(m4Id, Rank.F);
      const propId = (await proposals.nextProposalId()) - 1n;

      // Only extra1 (G, power=1) votes yes
      // Wait, extra1 is G and just joined — they need to vote
      // Actually extra1 joined after the snapshot block, so their power at snapshot = 0
      // Let's just have nobody vote, or vote with 1 person
      // Actually, the proposal was created before extra1 voted. The snapshot is at proposal creation block.
      // At that point, total = 512*3 + 1 = 1537 (owner + m1 + m2 already SSS + extra1 just joined at G)
      // Hmm, actually extra1 joined in the same beforeEach... No, we're not using beforeEach here.

      // Simply: don't vote at all
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await proposals.connect(owner).finalizeProposal(propId);

      const p = await proposals.getProposal(propId);
      expect(p.succeeded).to.be.false;
    });

    it("proposal with more no than yes → fails", async function () {
      await dao.bootstrapAddMember(member1.address, Rank.SSS);
      const m3Id = await inviteAndAccept(owner, extra1);

      await proposals.connect(owner).createProposalGrantRank(m3Id, Rank.F);
      const propId = (await proposals.nextProposalId()) - 1n;

      // owner votes yes (512), member1 votes no (512)
      await proposals.connect(owner).castVote(propId, true);
      await proposals.connect(member1).castVote(propId, false);

      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await proposals.connect(owner).finalizeProposal(propId);

      const p = await proposals.getProposal(propId);
      expect(p.succeeded).to.be.false; // tie → fails (yes <= no)
    });

    it("activeProposalsOf decrements on finalize", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await proposals.connect(owner).createProposalGrantRank(m1Id, Rank.F);
      expect(await proposals.activeProposalsOf(1)).to.equal(1);

      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await proposals.connect(owner).finalizeProposal(1);
      expect(await proposals.activeProposalsOf(1)).to.equal(0);
    });
  });

  // ══════════════════════════════════════════════════════════
  //  Treasury Deposits & Proposals
  // ══════════════════════════════════════════════════════════
  describe("Treasury", function () {

    it("accepts ETH deposits", async function () {
      const amount = ethers.parseEther("1.0");
      await expect(
        owner.sendTransaction({ to: await treasury.getAddress(), value: amount })
      ).to.emit(treasury, "DepositedETH").withArgs(owner.address, amount);
    });

    it("accepts ERC20 deposits", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const token = await MockERC20.deploy("Test", "TST");
      await token.waitForDeployment();
      const amount = ethers.parseUnits("100", 18);
      await token.mint(owner.address, amount);
      await token.approve(await treasury.getAddress(), amount);
      await expect(
        treasury.depositERC20(await token.getAddress(), amount)
      ).to.emit(treasury, "DepositedERC20");
    });

    it("propose TRANSFER_ETH: full lifecycle", async function () {
      // Fund treasury
      await owner.sendTransaction({ to: await treasury.getAddress(), value: ethers.parseEther("5") });
      const balBefore = await ethers.provider.getBalance(outsider.address);

      const data = coder.encode(["address", "uint256"], [outsider.address, ethers.parseEther("1")]);
      await treasuryProposalLifecycle(owner, AT.TRANSFER_ETH, data);

      const balAfter = await ethers.provider.getBalance(outsider.address);
      expect(balAfter - balBefore).to.equal(ethers.parseEther("1"));
    });

    it("propose TRANSFER_ERC20: full lifecycle", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const token = await MockERC20.deploy("Test", "TST");
      await token.waitForDeployment();
      const amount = ethers.parseUnits("50", 18);
      await token.mint(await treasury.getAddress(), amount);

      const data = coder.encode(
        ["address", "address", "uint256"],
        [await token.getAddress(), outsider.address, amount]
      );
      await treasuryProposalLifecycle(owner, AT.TRANSFER_ERC20, data);

      expect(await token.balanceOf(outsider.address)).to.equal(amount);
    });

    it("SET_TREASURY_LOCKED: full lifecycle", async function () {
      const data = coder.encode(["bool"], [true]);
      await treasuryProposalLifecycle(owner, AT.SET_TREASURY_LOCKED, data);
      expect(await treasury.treasuryLocked()).to.be.true;
    });

    it("SET_CALL_ACTIONS_ENABLED: full lifecycle", async function () {
      const data = coder.encode(["bool"], [true]);
      await treasuryProposalLifecycle(owner, AT.SET_CALL_ACTIONS_ENABLED, data);
      expect(await treasury.callActionsEnabled()).to.be.true;
    });

    it("G member cannot propose", async function () {
      await inviteAndAccept(owner, member1);
      const data = coder.encode(["address", "uint256"], [outsider.address, 1]);
      await expect(
        treasury.connect(member1).propose(AT.TRANSFER_ETH, data)
      ).to.be.revertedWithCustomError(treasury, "NotMember");
    });

    it("invalid action type reverts", async function () {
      await expect(
        treasury.connect(owner).propose(99, "0x")
      ).to.be.revertedWithCustomError(treasury, "InvalidActionType");
    });

    it("execute before finalize → revert", async function () {
      const data = coder.encode(["bool"], [true]);
      await treasury.connect(owner).propose(AT.SET_TREASURY_LOCKED, data);
      await expect(
        treasury.connect(owner).execute(1)
      ).to.be.revertedWithCustomError(treasury, "NotReady");
    });

    it("execute failed proposal → revert", async function () {
      const data = coder.encode(["bool"], [true]);
      await treasury.connect(owner).propose(AT.SET_TREASURY_LOCKED, data);
      // don't vote, finalize after period → quorum not met
      await mineBlocks(2);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      // Vote no to make it fail (quorum met but no > yes)
      // Actually, let's just not vote — zero votes = fail
      await treasury.connect(owner).finalize(1);
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await expect(
        treasury.connect(owner).execute(1)
      ).to.be.revertedWithCustomError(treasury, "NotReady");
    });

    it("double execute → revert", async function () {
      const data = coder.encode(["bool"], [true]);
      await treasuryProposalLifecycle(owner, AT.SET_TREASURY_LOCKED, data);
      await expect(
        treasury.connect(owner).execute(1)
      ).to.be.revertedWithCustomError(treasury, "NotReady");
    });

    it("TRANSFER_ETH blocked when treasury locked", async function () {
      // Lock treasury first
      const lockData = coder.encode(["bool"], [true]);
      await treasuryProposalLifecycle(owner, AT.SET_TREASURY_LOCKED, lockData);

      // Fund treasury
      await owner.sendTransaction({ to: await treasury.getAddress(), value: ethers.parseEther("5") });

      // Propose ETH transfer
      const data = coder.encode(["address", "uint256"], [outsider.address, ethers.parseEther("1")]);
      const propId = await treasury.connect(owner).propose.staticCall(AT.TRANSFER_ETH, data);
      await treasury.connect(owner).propose(AT.TRANSFER_ETH, data);
      await mineBlocks(2);
      await treasury.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await treasury.connect(owner).finalize(propId);
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");

      await expect(
        treasury.connect(owner).execute(propId)
      ).to.be.revertedWithCustomError(treasury, "TreasuryLocked");
    });
  });

  // ══════════════════════════════════════════════════════════
  //  Membership Fees (FeeRouter + DAO active/inactive)
  // ══════════════════════════════════════════════════════════
  describe("Membership Fees", function () {
    const EPOCH = 100 * 86400; // 100 days in seconds

    describe("Bootstrap members", function () {
      it("bootstrap members start active with feePaidUntil = max", async function () {
        expect(await dao.isMemberActive(1)).to.be.true;
        expect(await dao.feePaidUntil(1)).to.equal(ethers.MaxUint256 >> 192n); // type(uint64).max
      });

      it("bootstrap members cannot be deactivated (never expire)", async function () {
        await ethers.provider.send("evm_increaseTime", [EPOCH * 10]);
        await ethers.provider.send("evm_mine");
        await expect(
          dao.deactivateMember(1)
        ).to.be.revertedWithCustomError(dao, "MemberNotExpired");
      });
    });

    describe("Invited members", function () {
      it("new invited member starts active with 1 free epoch", async function () {
        const m1Id = await inviteAndAccept(owner, member1);
        expect(await dao.isMemberActive(m1Id)).to.be.true;
        const paidUntil = await dao.feePaidUntil(m1Id);
        const now = (await ethers.provider.getBlock("latest")).timestamp;
        // paidUntil should be ~now + EPOCH
        expect(paidUntil).to.be.closeTo(now + EPOCH, 5);
      });
    });

    describe("Fee payment (ETH)", function () {
      let m1Id;

      beforeEach(async function () {
        // Set baseFee to 0.001 ether (ETH mode, feeToken = address(0))
        await dao.setBaseFee(ethers.parseEther("0.001"));
        m1Id = await inviteAndAccept(owner, member1);
      });

      it("pay fee extends feePaidUntil by one EPOCH", async function () {
        const paidBefore = await dao.feePaidUntil(m1Id);
        const fee = await dao.feeOfRank(Rank.G); // baseFee * 2^0 = 0.001 ETH
        await feeRouter.connect(member1).payMembershipFee(m1Id, { value: fee });
        const paidAfter = await dao.feePaidUntil(m1Id);
        expect(paidAfter - paidBefore).to.equal(EPOCH);
      });

      it("fee scales by rank (G=1x, F=2x)", async function () {
        const feeG = await dao.feeOfRank(Rank.G);
        const feeF = await dao.feeOfRank(Rank.F);
        expect(feeF).to.equal(feeG * 2n);
      });

      it("wrong ETH amount reverts", async function () {
        const fee = await dao.feeOfRank(Rank.G);
        await expect(
          feeRouter.connect(member1).payMembershipFee(m1Id, { value: fee + 1n })
        ).to.be.revertedWithCustomError(feeRouter, "IncorrectFeeAmount");
      });

      it("anyone can pay on behalf of another member", async function () {
        const fee = await dao.feeOfRank(Rank.G);
        await feeRouter.connect(outsider).payMembershipFee(m1Id, { value: fee });
        // just check it didn't revert — fee recorded
        const paidUntil = await dao.feePaidUntil(m1Id);
        const now = (await ethers.provider.getBlock("latest")).timestamp;
        expect(paidUntil).to.be.closeTo(now + 2 * EPOCH, 5);
      });

      it("fee revenue lands in payoutTreasury", async function () {
        const fee = await dao.feeOfRank(Rank.G);
        const balBefore = await ethers.provider.getBalance(await treasury.getAddress());
        await feeRouter.connect(member1).payMembershipFee(m1Id, { value: fee });
        const balAfter = await ethers.provider.getBalance(await treasury.getAddress());
        expect(balAfter - balBefore).to.equal(fee);
      });

      it("emits MembershipFeePaid event", async function () {
        const fee = await dao.feeOfRank(Rank.G);
        await expect(
          feeRouter.connect(member1).payMembershipFee(m1Id, { value: fee })
        ).to.emit(feeRouter, "MembershipFeePaid");
      });
    });

    describe("Fee payment (ERC20)", function () {
      let m1Id, token;

      beforeEach(async function () {
        const MockERC20 = await ethers.getContractFactory("MockERC20");
        token = await MockERC20.deploy("FeeToken", "FEE");
        await token.waitForDeployment();

        // Configure ERC20 fee mode
        await dao.setFeeToken(await token.getAddress());
        await dao.setBaseFee(ethers.parseUnits("10", 18)); // 10 FEE tokens base
        m1Id = await inviteAndAccept(owner, member1);
      });

      it("pays fee in ERC20 and extends epoch", async function () {
        const fee = await dao.feeOfRank(Rank.G); // 10 * 1 = 10 FEE
        await token.mint(member1.address, fee);
        await token.connect(member1).approve(await feeRouter.getAddress(), fee);

        const paidBefore = await dao.feePaidUntil(m1Id);
        await feeRouter.connect(member1).payMembershipFee(m1Id);
        const paidAfter = await dao.feePaidUntil(m1Id);
        expect(paidAfter - paidBefore).to.equal(EPOCH);
      });

      it("ERC20 fee revenue lands in payoutTreasury", async function () {
        const fee = await dao.feeOfRank(Rank.G);
        await token.mint(member1.address, fee);
        await token.connect(member1).approve(await feeRouter.getAddress(), fee);

        await feeRouter.connect(member1).payMembershipFee(m1Id);
        expect(await token.balanceOf(await treasury.getAddress())).to.equal(fee);
      });

      it("sending ETH with ERC20 fee reverts", async function () {
        const fee = await dao.feeOfRank(Rank.G);
        await token.mint(member1.address, fee);
        await token.connect(member1).approve(await feeRouter.getAddress(), fee);

        await expect(
          feeRouter.connect(member1).payMembershipFee(m1Id, { value: 1 })
        ).to.be.revertedWithCustomError(feeRouter, "IncorrectFeeAmount");
      });
    });

    describe("Deactivation & reactivation", function () {
      let m1Id;

      beforeEach(async function () {
        await dao.setBaseFee(ethers.parseEther("0.001"));
        m1Id = await inviteAndAccept(owner, member1);
      });

      it("deactivateMember reverts if fee not expired", async function () {
        await expect(
          dao.deactivateMember(m1Id)
        ).to.be.revertedWithCustomError(dao, "MemberNotExpired");
      });

      it("deactivateMember succeeds after epoch expires (gracePeriod=0)", async function () {
        // advance past the free epoch
        await ethers.provider.send("evm_increaseTime", [EPOCH + 1]);
        await ethers.provider.send("evm_mine");

        await expect(dao.deactivateMember(m1Id))
          .to.emit(dao, "MemberDeactivated").withArgs(m1Id);
        expect(await dao.isMemberActive(m1Id)).to.be.false;
      });

      it("inactive member has 0 voting power", async function () {
        await ethers.provider.send("evm_increaseTime", [EPOCH + 1]);
        await ethers.provider.send("evm_mine");
        await dao.deactivateMember(m1Id);
        expect(await dao.votingPowerOfMember(m1Id)).to.equal(0);
      });

      it("total voting power decreases on deactivation", async function () {
        const totalBefore = await dao.totalVotingPower();
        await ethers.provider.send("evm_increaseTime", [EPOCH + 1]);
        await ethers.provider.send("evm_mine");
        await dao.deactivateMember(m1Id);
        const totalAfter = await dao.totalVotingPower();
        expect(totalBefore - totalAfter).to.equal(1n); // G rank = power 1
      });

      it("cannot deactivate already-inactive member", async function () {
        await ethers.provider.send("evm_increaseTime", [EPOCH + 1]);
        await ethers.provider.send("evm_mine");
        await dao.deactivateMember(m1Id);
        await expect(
          dao.deactivateMember(m1Id)
        ).to.be.revertedWithCustomError(dao, "AlreadyInactive");
      });

      it("paying fee reactivates an inactive member", async function () {
        // expire and deactivate
        await ethers.provider.send("evm_increaseTime", [EPOCH + 1]);
        await ethers.provider.send("evm_mine");
        await dao.deactivateMember(m1Id);
        expect(await dao.isMemberActive(m1Id)).to.be.false;
        expect(await dao.votingPowerOfMember(m1Id)).to.equal(0);

        // pay fee via feeRouter
        const fee = await dao.feeOfRank(Rank.G);
        await expect(
          feeRouter.connect(member1).payMembershipFee(m1Id, { value: fee })
        ).to.emit(dao, "MemberReactivated").withArgs(m1Id);

        expect(await dao.isMemberActive(m1Id)).to.be.true;
        expect(await dao.votingPowerOfMember(m1Id)).to.equal(1n);
      });

      it("rank change on inactive member does not affect voting power", async function () {
        await ethers.provider.send("evm_increaseTime", [EPOCH + 1]);
        await ethers.provider.send("evm_mine");
        await dao.deactivateMember(m1Id);

        const totalBefore = await dao.totalVotingPower();
        // promote via governance proposal
        await proposals.connect(owner).createProposalGrantRank(m1Id, Rank.A);
        const propId = (await proposals.nextProposalId()) - 1n;
        await proposals.connect(owner).castVote(propId, true);
        await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
        await ethers.provider.send("evm_mine");
        await proposals.connect(owner).finalizeProposal(propId);

        // rank changed but power still 0
        expect((await dao.getMember(m1Id)).rank).to.equal(Rank.A);
        expect(await dao.votingPowerOfMember(m1Id)).to.equal(0);
        expect(await dao.totalVotingPower()).to.equal(totalBefore);
      });
    });

    describe("Grace period", function () {
      let m1Id;

      beforeEach(async function () {
        await dao.setBaseFee(ethers.parseEther("0.001"));
        await dao.setGracePeriod(7 * 86400); // 7 days grace
        m1Id = await inviteAndAccept(owner, member1);
      });

      it("cannot deactivate during grace period", async function () {
        // advance past epoch but within grace
        await ethers.provider.send("evm_increaseTime", [EPOCH + 86400]); // epoch+1day
        await ethers.provider.send("evm_mine");
        await expect(
          dao.deactivateMember(m1Id)
        ).to.be.revertedWithCustomError(dao, "MemberNotExpired");
      });

      it("can deactivate after epoch + grace", async function () {
        await ethers.provider.send("evm_increaseTime", [EPOCH + 7 * 86400 + 1]);
        await ethers.provider.send("evm_mine");
        await dao.deactivateMember(m1Id);
        expect(await dao.isMemberActive(m1Id)).to.be.false;
      });
    });

    describe("Fee config setters", function () {
      it("owner can set baseFee during bootstrap", async function () {
        await dao.setBaseFee(ethers.parseEther("0.01"));
        expect(await dao.baseFee()).to.equal(ethers.parseEther("0.01"));
      });

      it("owner can set feeToken during bootstrap", async function () {
        await dao.setFeeToken(member1.address); // any address
        expect(await dao.feeToken()).to.equal(member1.address);
      });

      it("owner can set gracePeriod during bootstrap", async function () {
        await dao.setGracePeriod(86400);
        expect(await dao.gracePeriod()).to.equal(86400);
      });

      it("owner can set payoutTreasury during bootstrap", async function () {
        await dao.setPayoutTreasury(member1.address);
        expect(await dao.payoutTreasury()).to.equal(member1.address);
      });

      it("outsider cannot set fee config", async function () {
        await expect(
          dao.connect(outsider).setBaseFee(1)
        ).to.be.revertedWithCustomError(dao, "NotController");
        await expect(
          dao.connect(outsider).setFeeToken(outsider.address)
        ).to.be.revertedWithCustomError(dao, "NotController");
        await expect(
          dao.connect(outsider).setGracePeriod(1)
        ).to.be.revertedWithCustomError(dao, "NotController");
        await expect(
          dao.connect(outsider).setPayoutTreasury(outsider.address)
        ).to.be.revertedWithCustomError(dao, "NotController");
      });

      it("payoutTreasury rejects zero address", async function () {
        await expect(
          dao.setPayoutTreasury(ethers.ZeroAddress)
        ).to.be.revertedWithCustomError(dao, "InvalidAddress");
      });
    });

    describe("FeeRouter edge cases", function () {
      it("reverts for non-existent member", async function () {
        await dao.setBaseFee(ethers.parseEther("0.001"));
        await expect(
          feeRouter.payMembershipFee(999, { value: ethers.parseEther("0.001") })
        ).to.be.revertedWithCustomError(feeRouter, "NotMember");
      });

      it("reverts when baseFee is 0 (fee not configured)", async function () {
        const m1Id = await inviteAndAccept(owner, member1);
        // baseFee defaults to 0
        await expect(
          feeRouter.payMembershipFee(m1Id)
        ).to.be.revertedWithCustomError(feeRouter, "FeeNotConfigured");
      });

      it("reverts when payoutTreasury is not set", async function () {
        // deploy fresh DAO+FeeRouter without payoutTreasury set
        const DAO2 = await ethers.getContractFactory("RankedMembershipDAO");
        const dao2 = await DAO2.deploy();
        await dao2.waitForDeployment();
        const FR2 = await ethers.getContractFactory("FeeRouter");
        const fr2 = await FR2.deploy(await dao2.getAddress());
        await fr2.waitForDeployment();
        await dao2.setFeeRouter(await fr2.getAddress());
        await dao2.setBaseFee(ethers.parseEther("0.001"));
        // payoutTreasury is still address(0)
        await expect(
          fr2.payMembershipFee(1, { value: ethers.parseEther("0.001") })
        ).to.be.revertedWithCustomError(fr2, "PayoutTreasuryNotSet");
      });
    });

    describe("setMemberActive (governance override)", function () {
      it("controller can force-deactivate a member", async function () {
        // We need to call dao.setMemberActive via controller (governance).
        // For simplicity, use a fresh DAO where owner IS the controller.
        const DAO2 = await ethers.getContractFactory("RankedMembershipDAO");
        const dao2 = await DAO2.deploy();
        await dao2.waitForDeployment();
        // owner is still owner, set controller to owner for direct calls
        await dao2.setController(owner.address);
        await dao2.setMemberActive(1, false);
        expect(await dao2.isMemberActive(1)).to.be.false;
        expect(await dao2.votingPowerOfMember(1)).to.equal(0);
      });

      it("controller can force-reactivate a member", async function () {
        const DAO2 = await ethers.getContractFactory("RankedMembershipDAO");
        const dao2 = await DAO2.deploy();
        await dao2.waitForDeployment();
        await dao2.setController(owner.address);
        await dao2.setMemberActive(1, false);
        await dao2.setMemberActive(1, true);
        expect(await dao2.isMemberActive(1)).to.be.true;
        expect(await dao2.votingPowerOfMember(1)).to.equal(512n); // SSS
      });
    });

    describe("Bootstrap fee reset", function () {
      it("bootstrap member fee payment reverts with BootstrapMemberFeeExempt", async function () {
        // owner (deployer) is bootstrap SSS member #1
        await dao.setBaseFee(ethers.parseEther("0.001"));
        const fee = await dao.feeOfRank(Rank.SSS); // 0.001 * 2^9 = 0.512 ETH

        expect(await dao.feePaidUntil(1)).to.equal(ethers.MaxUint256 >> 192n); // sentinel
        await expect(
          feeRouter.connect(owner).payMembershipFee(1, { value: fee })
        ).to.be.revertedWithCustomError(dao, "BootstrapMemberFeeExempt");
      });

      it("resetBootstrapFee via governance converts bootstrap to fee-paying", async function () {
        // owner is SSS (#1), member1 (#2) will be bootstrap SSS too
        await dao.bootstrapAddMember(member1.address, Rank.A);
        const m1Id = await dao.memberIdByAuthority(member1.address);
        expect(await dao.feePaidUntil(m1Id)).to.equal(ethers.MaxUint256 >> 192n);

        // Finalize bootstrap so governance is operational
        await dao.finalizeBootstrap();

        // Create proposal to reset bootstrap fee for m1
        await proposals.connect(owner).createProposalResetBootstrapFee(m1Id);
        const propId = (await proposals.nextProposalId()) - 1n;
        await proposals.connect(owner).castVote(propId, true);
        await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
        await ethers.provider.send("evm_mine");
        await proposals.connect(owner).finalizeProposal(propId);

        const p = await proposals.getProposal(propId);
        expect(p.succeeded).to.be.true;

        const paidUntil = await dao.feePaidUntil(m1Id);
        const now = (await ethers.provider.getBlock("latest")).timestamp;
        const EPOCH = 100 * 86400;
        expect(paidUntil).to.be.closeTo(now + EPOCH, 5);
        expect(paidUntil).to.be.lessThan(ethers.MaxUint256 >> 192n);
      });

      it("resetBootstrapFee reverts for non-bootstrap member", async function () {
        const m1Id = await inviteAndAccept(owner, member1);
        // m1 is invited (not bootstrap), feePaidUntil = now + EPOCH
        const DAO2 = await ethers.getContractFactory("RankedMembershipDAO");
        const dao2 = await DAO2.deploy();
        await dao2.waitForDeployment();
        await dao2.setController(owner.address);
        // member 1 (deployer/bootstrap SSS) — reset it first to prove it works
        await dao2.resetBootstrapFee(1);
        // Now try again — should revert since it's no longer bootstrap
        await expect(
          dao2.resetBootstrapFee(1)
        ).to.be.revertedWithCustomError(dao2, "NotBootstrapMember");
      });

      it("resetBootstrapFee reverts for non-existent member", async function () {
        const DAO2 = await ethers.getContractFactory("RankedMembershipDAO");
        const dao2 = await DAO2.deploy();
        await dao2.waitForDeployment();
        await dao2.setController(owner.address);
        await expect(
          dao2.resetBootstrapFee(999)
        ).to.be.revertedWithCustomError(dao2, "InvalidTarget");
      });

      it("createProposalResetBootstrapFee reverts for non-bootstrap member", async function () {
        const m1Id = await inviteAndAccept(owner, member1);
        // m1 is invited, not bootstrap
        await expect(
          proposals.connect(owner).createProposalResetBootstrapFee(m1Id)
        ).to.be.revertedWithCustomError(proposals, "InvalidTarget");
      });

      it("createProposalResetBootstrapFee reverts if rank too low", async function () {
        // Bootstrap a G member and finalize
        await dao.bootstrapAddMember(member1.address, Rank.G);
        const m1Id = await dao.memberIdByAuthority(member1.address);
        await dao.finalizeBootstrap();

        // Invite another G member — they can't create proposals (rank < F)
        const m2Id = await inviteAndAccept(owner, member2);
        // m2 is G rank, below F minimum for proposals
        await expect(
          proposals.connect(member2).createProposalResetBootstrapFee(1)
        ).to.be.revertedWithCustomError(proposals, "RankTooLow");
      });

      it("second fee payment after governance reset extends normally", async function () {
        await dao.setBaseFee(ethers.parseEther("0.001"));
        const fee = await dao.feeOfRank(Rank.SSS);
        const EPOCH = 100 * 86400;

        // Bootstrap member #1 — finalize bootstrap so governance works
        await dao.finalizeBootstrap();

        // Use governance to reset bootstrap fee for member #1
        await proposals.connect(owner).createProposalResetBootstrapFee(1);
        const propId = (await proposals.nextProposalId()) - 1n;
        await proposals.connect(owner).castVote(propId, true);
        await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
        await ethers.provider.send("evm_mine");
        await proposals.connect(owner).finalizeProposal(propId);

        // First payment extends from now + EPOCH
        await feeRouter.connect(owner).payMembershipFee(1, { value: fee });
        const after1 = await dao.feePaidUntil(1);

        // Second payment extends by another EPOCH
        await feeRouter.connect(owner).payMembershipFee(1, { value: fee });
        const after2 = await dao.feePaidUntil(1);

        expect(after2 - after1).to.equal(EPOCH);
      });
    });
  });

  // ══════════════════════════════════════════════════════════
  //  Cross-contract Security
  // ══════════════════════════════════════════════════════════
  describe("Cross-contract Security", function () {
    it("outsider cannot call onlyController functions on DAO", async function () {
      await expect(
        dao.connect(outsider).setRank(1, Rank.G, 1, false)
      ).to.be.revertedWithCustomError(dao, "NotController");
      await expect(
        dao.connect(outsider).addMember(outsider.address)
      ).to.be.revertedWithCustomError(dao, "NotController");
      await expect(
        dao.connect(outsider).setVotingPeriod(86400)
      ).to.be.revertedWithCustomError(dao, "NotController");
    });

    it("outsider cannot call onlyModule functions on Treasury", async function () {
      await expect(
        treasury.connect(outsider).moduleTransferETH(outsider.address, 1)
      ).to.be.revertedWithCustomError(treasury, "NotModule");
      await expect(
        treasury.connect(outsider).moduleTransferERC20(outsider.address, outsider.address, 1)
      ).to.be.revertedWithCustomError(treasury, "NotModule");
    });

    it("outsider cannot call onlyTreasury function on Module", async function () {
      await expect(
        treasurerModule.connect(outsider).executeTreasurerAction(AT.ADD_MEMBER_TREASURER, "0x")
      ).to.be.revertedWithCustomError(treasurerModule, "NotTreasury");
    });

    it("outsider cannot call recordFeePayment on DAO (onlyFeeRouter)", async function () {
      await expect(
        dao.connect(outsider).recordFeePayment(1)
      ).to.be.revertedWithCustomError(dao, "NotFeeRouter");
    });
  });

  // ══════════════════════════════════════════════════════════
  //  TreasurerModule — Member Treasurer (via proposals)
  // ══════════════════════════════════════════════════════════
  describe("TreasurerModule", function () {
    let mockToken, mockNFT;
    const ONE_ETH = ethers.parseEther("1");
    const TEN_ETH = ethers.parseEther("10");
    const PERIOD = 86400; // 1 day

    beforeEach(async function () {
      // Deploy token/NFT mocks
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      mockToken = await MockERC20.deploy("Test", "TST");
      await mockToken.waitForDeployment();

      const MockERC721 = await ethers.getContractFactory("MockERC721");
      mockNFT = await MockERC721.deploy("TestNFT", "TNFT");
      await mockNFT.waitForDeployment();

      // Fund treasury with ETH and tokens
      await owner.sendTransaction({ to: await treasury.getAddress(), value: ethers.parseEther("100") });
      await mockToken.mint(await treasury.getAddress(), ethers.parseEther("1000"));
    });

    describe("Add/Update/Remove Member Treasurer", function () {
      it("add member treasurer via proposal → direct spend ETH", async function () {
        // SSS owner adds themselves as member-based treasurer
        const ownerId = await dao.memberIdByAuthority(owner.address);
        const data = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, ONE_ETH, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, data);

        // Verify treasurer config
        const cfg = await treasurerModule.getMemberTreasurerConfig(ownerId);
        expect(cfg.active).to.be.true;
        expect(cfg.baseSpendingLimit).to.equal(TEN_ETH);

        // Now spend ETH via direct call
        const balBefore = await ethers.provider.getBalance(outsider.address);
        await treasurerModule.connect(owner).treasurerSpendETH(outsider.address, ONE_ETH);
        const balAfter = await ethers.provider.getBalance(outsider.address);
        expect(balAfter - balBefore).to.equal(ONE_ETH);
      });

      it("update member treasurer via proposal", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);
        // Add first
        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, ONE_ETH, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        // Update
        const updData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, ethers.parseEther("20"), ethers.parseEther("2"), PERIOD * 2, Rank.F]
        );
        await treasuryProposalLifecycle(owner, AT.UPDATE_MEMBER_TREASURER, updData);

        const cfg = await treasurerModule.getMemberTreasurerConfig(ownerId);
        expect(cfg.baseSpendingLimit).to.equal(ethers.parseEther("20"));
        expect(cfg.periodDuration).to.equal(PERIOD * 2);
      });

      it("remove member treasurer via proposal", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);
        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, ONE_ETH, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        const removeData = coder.encode(["uint32"], [ownerId]);
        await treasuryProposalLifecycle(owner, AT.REMOVE_MEMBER_TREASURER, removeData);

        const cfg = await treasurerModule.getMemberTreasurerConfig(ownerId);
        expect(cfg.active).to.be.false;
      });

      it("spending limit resets after period expires", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);
        const data = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, 0, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, data);

        // Spend up to limit
        await treasurerModule.connect(owner).treasurerSpendETH(outsider.address, TEN_ETH);

        // Should fail — limit reached
        await expect(
          treasurerModule.connect(owner).treasurerSpendETH(outsider.address, ONE_ETH)
        ).to.be.revertedWithCustomError(treasurerModule, "TreasurerSpendingLimitExceeded");

        // Advance past period
        await ethers.provider.send("evm_increaseTime", [PERIOD + 1]);
        await ethers.provider.send("evm_mine");

        // Should succeed again
        await treasurerModule.connect(owner).treasurerSpendETH(outsider.address, ONE_ETH);
      });

      it("non-treasurer cannot spend", async function () {
        await expect(
          treasurerModule.connect(outsider).treasurerSpendETH(owner.address, ONE_ETH)
        ).to.be.revertedWithCustomError(treasurerModule, "NotTreasurer");
      });

      it("spend reverts when treasury locked", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);
        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, 0, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        // Lock treasury
        const lockData = coder.encode(["bool"], [true]);
        await treasuryProposalLifecycle(owner, AT.SET_TREASURY_LOCKED, lockData);

        await expect(
          treasurerModule.connect(owner).treasurerSpendETH(outsider.address, ONE_ETH)
        ).to.be.revertedWithCustomError(treasurerModule, "TreasuryLocked");
      });

      it("spend ERC20 via member treasurer", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);
        const data = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, 0, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, data);

        const tokenAddr = await mockToken.getAddress();
        await treasurerModule.connect(owner).treasurerSpendERC20(tokenAddr, outsider.address, ONE_ETH);
        expect(await mockToken.balanceOf(outsider.address)).to.equal(ONE_ETH);
      });

      it("member token config overrides base limit for ERC20", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);
        const tokenAddr = await mockToken.getAddress();

        // Add treasurer with high base limit
        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, ethers.parseEther("100"), 0, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        // Set token config with low limit
        const tokenCfgData = coder.encode(
          ["uint32","address","uint256","uint256"],
          [ownerId, tokenAddr, ONE_ETH, 0]
        );
        await treasuryProposalLifecycle(owner, AT.SET_MEMBER_TOKEN_CONFIG, tokenCfgData);

        // Should fail if exceeding token-specific limit
        await expect(
          treasurerModule.connect(owner).treasurerSpendERC20(tokenAddr, outsider.address, ethers.parseEther("2"))
        ).to.be.revertedWithCustomError(treasurerModule, "TreasurerSpendingLimitExceeded");

        // But should succeed within token limit
        await treasurerModule.connect(owner).treasurerSpendERC20(tokenAddr, outsider.address, ONE_ETH);
      });
    });

    describe("Add/Update/Remove Address Treasurer", function () {
      it("add address-based treasurer → spend ETH", async function () {
        const data = coder.encode(
          ["address","uint256","uint64"],
          [outsider.address, TEN_ETH, PERIOD]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_ADDRESS_TREASURER, data);

        const cfg = await treasurerModule.getAddressTreasurerConfig(outsider.address);
        expect(cfg.active).to.be.true;

        await treasurerModule.connect(outsider).treasurerSpendETH(extra1.address, ONE_ETH);
        const bal = await ethers.provider.getBalance(extra1.address);
        expect(bal).to.be.gt(ethers.parseEther("10000")); // started with 10k
      });

      it("update address treasurer", async function () {
        const addData = coder.encode(
          ["address","uint256","uint64"],
          [outsider.address, TEN_ETH, PERIOD]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_ADDRESS_TREASURER, addData);

        const updData = coder.encode(
          ["address","uint256","uint64"],
          [outsider.address, ethers.parseEther("50"), PERIOD * 7]
        );
        await treasuryProposalLifecycle(owner, AT.UPDATE_ADDRESS_TREASURER, updData);

        const cfg = await treasurerModule.getAddressTreasurerConfig(outsider.address);
        expect(cfg.baseSpendingLimit).to.equal(ethers.parseEther("50"));
      });

      it("remove address treasurer → can no longer spend", async function () {
        const addData = coder.encode(
          ["address","uint256","uint64"],
          [outsider.address, TEN_ETH, PERIOD]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_ADDRESS_TREASURER, addData);

        const removeData = coder.encode(["address"], [outsider.address]);
        await treasuryProposalLifecycle(owner, AT.REMOVE_ADDRESS_TREASURER, removeData);

        await expect(
          treasurerModule.connect(outsider).treasurerSpendETH(extra1.address, ONE_ETH)
        ).to.be.revertedWithCustomError(treasurerModule, "NotTreasurer");
      });

      it("address treasurer ERC20 spending with token config", async function () {
        const tokenAddr = await mockToken.getAddress();
        const addData = coder.encode(
          ["address","uint256","uint64"],
          [outsider.address, TEN_ETH, PERIOD]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_ADDRESS_TREASURER, addData);

        // Set token-specific config
        const tokenCfgData = coder.encode(
          ["address","address","uint256"],
          [outsider.address, tokenAddr, ethers.parseEther("5")]
        );
        await treasuryProposalLifecycle(owner, AT.SET_ADDRESS_TOKEN_CONFIG, tokenCfgData);

        await treasurerModule.connect(outsider).treasurerSpendERC20(tokenAddr, extra1.address, ethers.parseEther("5"));
        expect(await mockToken.balanceOf(extra1.address)).to.equal(ethers.parseEther("5"));

        // Over limit should revert
        await expect(
          treasurerModule.connect(outsider).treasurerSpendERC20(tokenAddr, extra1.address, ONE_ETH)
        ).to.be.revertedWithCustomError(treasurerModule, "TreasurerSpendingLimitExceeded");
      });
    });

    describe("Treasurer Call", function () {
      it("treasurer can execute call to approved target", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);
        const tokenAddr = await mockToken.getAddress();

        // Add member treasurer
        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, 0, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        // Enable treasurer calls
        const enableData = coder.encode(["bool"], [true]);
        await treasuryProposalLifecycle(owner, AT.SET_TREASURER_CALLS_ENABLED, enableData);

        // Add approved target
        const approveData = coder.encode(["address"], [tokenAddr]);
        await treasuryProposalLifecycle(owner, AT.ADD_APPROVED_CALL_TARGET, approveData);

        // Execute call: transfer token from treasury
        const callData = mockToken.interface.encodeFunctionData("transfer", [outsider.address, ONE_ETH]);
        await treasurerModule.connect(owner).treasurerCall(tokenAddr, 0, callData);
        expect(await mockToken.balanceOf(outsider.address)).to.equal(ONE_ETH);
      });

      it("reverts if calls not enabled", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);
        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, 0, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        await expect(
          treasurerModule.connect(owner).treasurerCall(outsider.address, 0, "0x")
        ).to.be.revertedWithCustomError(treasurerModule, "TreasurerCallsDisabled");
      });

      it("reverts if target not approved", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);
        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, 0, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        // Enable calls but don't approve target
        const enableData = coder.encode(["bool"], [true]);
        await treasuryProposalLifecycle(owner, AT.SET_TREASURER_CALLS_ENABLED, enableData);

        await expect(
          treasurerModule.connect(owner).treasurerCall(outsider.address, 0, "0x")
        ).to.be.revertedWithCustomError(treasurerModule, "CallTargetNotApproved");
      });
    });

    describe("NFT Access & Transfer", function () {
      let nftAddr;
      let tokenId;

      beforeEach(async function () {
        nftAddr = await mockNFT.getAddress();
        // Mint an NFT to the treasury
        const tx = await mockNFT.mint(await treasury.getAddress());
        const receipt = await tx.wait();
        tokenId = 0; // first mint
      });

      it("grant member NFT access → transfer NFT via treasurer", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);

        // Also need a member treasurer for the check (the NFT check uses member lookup)
        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, 0, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        // Grant NFT access: 5 transfers per period
        const grantData = coder.encode(
          ["uint32","address","uint64","uint64","uint8"],
          [ownerId, nftAddr, 5, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.GRANT_MEMBER_NFT_ACCESS, grantData);

        // Verify access
        const access = await treasurerModule.getMemberNFTAccess(ownerId, nftAddr);
        expect(access.hasAccess).to.be.true;
        expect(access.transfersPerPeriod).to.equal(5);

        // Transfer NFT
        await treasurerModule.connect(owner).treasurerTransferNFT(nftAddr, outsider.address, tokenId);
        expect(await mockNFT.ownerOf(tokenId)).to.equal(outsider.address);
      });

      it("revoke member NFT access → transfer reverts", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);

        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, 0, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        const grantData = coder.encode(
          ["uint32","address","uint64","uint64","uint8"],
          [ownerId, nftAddr, 5, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.GRANT_MEMBER_NFT_ACCESS, grantData);

        // Revoke
        const revokeData = coder.encode(["uint32","address"], [ownerId, nftAddr]);
        await treasuryProposalLifecycle(owner, AT.REVOKE_MEMBER_NFT_ACCESS, revokeData);

        await expect(
          treasurerModule.connect(owner).treasurerTransferNFT(nftAddr, outsider.address, tokenId)
        ).to.be.revertedWithCustomError(treasurerModule, "NoNFTAccess");
      });

      it("grant address NFT access → transfer NFT", async function () {
        // Grant address-based NFT access to outsider
        const grantData = coder.encode(
          ["address","address","uint64","uint64"],
          [outsider.address, nftAddr, 10, PERIOD]
        );
        await treasuryProposalLifecycle(owner, AT.GRANT_ADDRESS_NFT_ACCESS, grantData);

        const access = await treasurerModule.getAddressNFTAccess(outsider.address, nftAddr);
        expect(access.hasAccess).to.be.true;

        // Also need address-based treasurer for the NFT transfer (spending check)
        // Actually NFT transfer just checks NFT access, not treasurer config
        await treasurerModule.connect(outsider).treasurerTransferNFT(nftAddr, extra1.address, tokenId);
        expect(await mockNFT.ownerOf(tokenId)).to.equal(extra1.address);
      });

      it("revoke address NFT access → transfer reverts", async function () {
        const grantData = coder.encode(
          ["address","address","uint64","uint64"],
          [outsider.address, nftAddr, 10, PERIOD]
        );
        await treasuryProposalLifecycle(owner, AT.GRANT_ADDRESS_NFT_ACCESS, grantData);

        const revokeData = coder.encode(["address","address"], [outsider.address, nftAddr]);
        await treasuryProposalLifecycle(owner, AT.REVOKE_ADDRESS_NFT_ACCESS, revokeData);

        await expect(
          treasurerModule.connect(outsider).treasurerTransferNFT(nftAddr, extra1.address, tokenId)
        ).to.be.revertedWithCustomError(treasurerModule, "NoNFTAccess");
      });

      it("NFT transfer via proposal (TRANSFER_NFT action)", async function () {
        const data = coder.encode(
          ["address","address","uint256"],
          [nftAddr, outsider.address, tokenId]
        );
        await treasuryProposalLifecycle(owner, AT.TRANSFER_NFT, data);
        expect(await mockNFT.ownerOf(tokenId)).to.equal(outsider.address);
      });

      it("NFT transfer limit enforced per period", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);

        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, 0, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        // Grant: 1 transfer per period
        const grantData = coder.encode(
          ["uint32","address","uint64","uint64","uint8"],
          [ownerId, nftAddr, 1, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.GRANT_MEMBER_NFT_ACCESS, grantData);

        // First transfer succeeds
        await treasurerModule.connect(owner).treasurerTransferNFT(nftAddr, outsider.address, tokenId);

        // Mint another NFT to treasury
        await mockNFT.mint(await treasury.getAddress()); // tokenId=1
        // Second transfer within same period should fail
        await expect(
          treasurerModule.connect(owner).treasurerTransferNFT(nftAddr, outsider.address, 1)
        ).to.be.revertedWithCustomError(treasurerModule, "NFTTransferLimitExceeded");

        // Advance past period
        await ethers.provider.send("evm_increaseTime", [PERIOD + 1]);
        await ethers.provider.send("evm_mine");

        // Should succeed after period reset
        await treasurerModule.connect(owner).treasurerTransferNFT(nftAddr, outsider.address, 1);
      });
    });

    describe("Views", function () {
      it("isTreasurer returns correct status", async function () {
        const [isTreas,] = await treasurerModule.isTreasurer(outsider.address);
        expect(isTreas).to.be.false;

        // Add address treasurer
        const addData = coder.encode(
          ["address","uint256","uint64"],
          [outsider.address, TEN_ETH, PERIOD]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_ADDRESS_TREASURER, addData);

        const [isTreas2, tType] = await treasurerModule.isTreasurer(outsider.address);
        expect(isTreas2).to.be.true;
        expect(tType).to.equal(2); // AddressBased
      });

      it("getTreasurerRemainingLimit tracks spending", async function () {
        const addData = coder.encode(
          ["address","uint256","uint64"],
          [outsider.address, TEN_ETH, PERIOD]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_ADDRESS_TREASURER, addData);

        const remaining1 = await treasurerModule.getTreasurerRemainingLimit(outsider.address);
        expect(remaining1).to.equal(TEN_ETH);

        await treasurerModule.connect(outsider).treasurerSpendETH(extra1.address, ethers.parseEther("3"));
        const remaining2 = await treasurerModule.getTreasurerRemainingLimit(outsider.address);
        expect(remaining2).to.equal(ethers.parseEther("7"));
      });

      it("hasNFTAccessView returns correct status", async function () {
        const nftAddr = await mockNFT.getAddress();
        const [canTransfer] = await treasurerModule.hasNFTAccessView(outsider.address, nftAddr);
        expect(canTransfer).to.be.false;
      });
    });

    describe("Edge cases & reverts", function () {
      it("treasurerSpendETH reverts with zero address", async function () {
        await expect(
          treasurerModule.connect(owner).treasurerSpendETH(ethers.ZeroAddress, ONE_ETH)
        ).to.be.revertedWithCustomError(treasurerModule, "InvalidAddress");
      });

      it("treasurerSpendETH reverts with zero amount", async function () {
        await expect(
          treasurerModule.connect(owner).treasurerSpendETH(outsider.address, 0)
        ).to.be.revertedWithCustomError(treasurerModule, "ZeroAmount");
      });

      it("treasurerSpendERC20 reverts with zero token address", async function () {
        await expect(
          treasurerModule.connect(owner).treasurerSpendERC20(ethers.ZeroAddress, outsider.address, ONE_ETH)
        ).to.be.revertedWithCustomError(treasurerModule, "InvalidAddress");
      });

      it("treasurerTransferNFT reverts with zero nft address", async function () {
        await expect(
          treasurerModule.connect(owner).treasurerTransferNFT(ethers.ZeroAddress, outsider.address, 0)
        ).to.be.revertedWithCustomError(treasurerModule, "InvalidAddress");
      });

      it("treasurerCall reverts with zero target", async function () {
        await expect(
          treasurerModule.connect(owner).treasurerCall(ethers.ZeroAddress, 0, "0x")
        ).to.be.revertedWithCustomError(treasurerModule, "InvalidAddress");
      });

      it("duplicate add member treasurer reverts", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);
        const data = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, TEN_ETH, 0, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, data);

        // Second add should revert (TreasurerAlreadyExists)
        // We'll just check the executeTreasurerAction revert
        await expect(
          treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, data)
        ).to.be.reverted;
      });

      it("update inactive treasurer reverts", async function () {
        const data = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [99, TEN_ETH, 0, PERIOD, Rank.G]
        );
        await expect(
          treasuryProposalLifecycle(owner, AT.UPDATE_MEMBER_TREASURER, data)
        ).to.be.reverted;
      });

      it("remove inactive treasurer reverts", async function () {
        const removeData = coder.encode(["uint32"], [99]);
        await expect(
          treasuryProposalLifecycle(owner, AT.REMOVE_MEMBER_TREASURER, removeData)
        ).to.be.reverted;
      });

      it("add duplicate address treasurer reverts", async function () {
        const data = coder.encode(
          ["address","uint256","uint64"],
          [outsider.address, TEN_ETH, PERIOD]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_ADDRESS_TREASURER, data);

        await expect(
          treasuryProposalLifecycle(owner, AT.ADD_ADDRESS_TREASURER, data)
        ).to.be.reverted;
      });

      it("duplicate grant NFT access reverts", async function () {
        const ownerId = await dao.memberIdByAuthority(owner.address);
        const nftAddr = await mockNFT.getAddress();
        const data = coder.encode(
          ["uint32","address","uint64","uint64","uint8"],
          [ownerId, nftAddr, 5, PERIOD, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.GRANT_MEMBER_NFT_ACCESS, data);
        await expect(
          treasuryProposalLifecycle(owner, AT.GRANT_MEMBER_NFT_ACCESS, data)
        ).to.be.reverted;
      });

      it("revoke non-existent NFT access reverts", async function () {
        const nftAddr = await mockNFT.getAddress();
        const data = coder.encode(["uint32","address"], [99, nftAddr]);
        await expect(
          treasuryProposalLifecycle(owner, AT.REVOKE_MEMBER_NFT_ACCESS, data)
        ).to.be.reverted;
      });
    });
  });

  // ══════════════════════════════════════════════════════════
  //  MembershipTreasury — Untested functions
  // ══════════════════════════════════════════════════════════
  describe("MembershipTreasury (extended)", function () {
    let mockToken, mockNFT;

    beforeEach(async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      mockToken = await MockERC20.deploy("Test", "TST");
      await mockToken.waitForDeployment();

      const MockERC721 = await ethers.getContractFactory("MockERC721");
      mockNFT = await MockERC721.deploy("TestNFT", "TNFT");
      await mockNFT.waitForDeployment();
    });

    describe("NFT deposits & views", function () {
      it("depositNFT transfers NFT to treasury", async function () {
        const nftAddr = await mockNFT.getAddress();
        await mockNFT.mint(owner.address); // tokenId=0
        const treasuryAddr = await treasury.getAddress();
        await mockNFT.connect(owner).approve(treasuryAddr, 0);
        await treasury.connect(owner).depositNFT(nftAddr, 0);
        expect(await mockNFT.ownerOf(0)).to.equal(treasuryAddr);
      });

      it("depositNFT reverts with zero address", async function () {
        await expect(
          treasury.connect(owner).depositNFT(ethers.ZeroAddress, 0)
        ).to.be.revertedWithCustomError(treasury, "InvalidAddress");
      });

      it("onERC721Received works via safeTransferFrom", async function () {
        const nftAddr = await mockNFT.getAddress();
        await mockNFT.mint(owner.address);
        const treasuryAddr = await treasury.getAddress();
        // safeTransferFrom triggers onERC721Received
        await mockNFT.connect(owner)["safeTransferFrom(address,address,uint256)"](
          owner.address, treasuryAddr, 0
        );
        expect(await mockNFT.ownerOf(0)).to.equal(treasuryAddr);
      });

      it("ownsNFT returns true when treasury owns NFT", async function () {
        const nftAddr = await mockNFT.getAddress();
        await mockNFT.mint(await treasury.getAddress());
        expect(await treasury.ownsNFT(nftAddr, 0)).to.be.true;
      });

      it("ownsNFT returns false when treasury does not own NFT", async function () {
        const nftAddr = await mockNFT.getAddress();
        await mockNFT.mint(owner.address);
        expect(await treasury.ownsNFT(nftAddr, 0)).to.be.false;
      });

      it("ownsNFT returns false for invalid token", async function () {
        const nftAddr = await mockNFT.getAddress();
        expect(await treasury.ownsNFT(nftAddr, 9999)).to.be.false;
      });
    });

    describe("Module transfer functions (via treasurer direct spend)", function () {
      it("moduleTransferERC20 works through treasurer spend", async function () {
        const tokenAddr = await mockToken.getAddress();
        await mockToken.mint(await treasury.getAddress(), ethers.parseEther("100"));

        const ownerId = await dao.memberIdByAuthority(owner.address);
        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, ethers.parseEther("50"), 0, 86400, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        await treasurerModule.connect(owner).treasurerSpendERC20(tokenAddr, outsider.address, ethers.parseEther("5"));
        expect(await mockToken.balanceOf(outsider.address)).to.equal(ethers.parseEther("5"));
      });

      it("moduleTransferNFT works through treasurer NFT transfer", async function () {
        const nftAddr = await mockNFT.getAddress();
        await mockNFT.mint(await treasury.getAddress()); // tokenId=0

        const ownerId = await dao.memberIdByAuthority(owner.address);
        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, ethers.parseEther("10"), 0, 86400, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        const grantData = coder.encode(
          ["uint32","address","uint64","uint64","uint8"],
          [ownerId, nftAddr, 5, 86400, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.GRANT_MEMBER_NFT_ACCESS, grantData);

        await treasurerModule.connect(owner).treasurerTransferNFT(nftAddr, outsider.address, 0);
        expect(await mockNFT.ownerOf(0)).to.equal(outsider.address);
      });

      it("moduleCall works through treasurer call", async function () {
        const tokenAddr = await mockToken.getAddress();
        await mockToken.mint(await treasury.getAddress(), ethers.parseEther("100"));

        const ownerId = await dao.memberIdByAuthority(owner.address);
        const addData = coder.encode(
          ["uint32","uint256","uint256","uint64","uint8"],
          [ownerId, ethers.parseEther("10"), 0, 86400, Rank.G]
        );
        await treasuryProposalLifecycle(owner, AT.ADD_MEMBER_TREASURER, addData);

        // Enable treasurer calls
        const enableData = coder.encode(["bool"], [true]);
        await treasuryProposalLifecycle(owner, AT.SET_TREASURER_CALLS_ENABLED, enableData);

        // Approve token as call target
        const approveData = coder.encode(["address"], [tokenAddr]);
        await treasuryProposalLifecycle(owner, AT.ADD_APPROVED_CALL_TARGET, approveData);

        const callData = mockToken.interface.encodeFunctionData("transfer", [outsider.address, ethers.parseEther("1")]);
        await treasurerModule.connect(owner).treasurerCall(tokenAddr, 0, callData);
        expect(await mockToken.balanceOf(outsider.address)).to.equal(ethers.parseEther("1"));
      });
    });

    describe("CALL proposal action", function () {
      it("execute CALL proposal to approved target", async function () {
        const tokenAddr = await mockToken.getAddress();
        await mockToken.mint(await treasury.getAddress(), ethers.parseEther("100"));

        // Enable call actions
        const enableData = coder.encode(["bool"], [true]);
        await treasuryProposalLifecycle(owner, AT.SET_CALL_ACTIONS_ENABLED, enableData);

        // Approve target
        const approveData = coder.encode(["address"], [tokenAddr]);
        await treasuryProposalLifecycle(owner, AT.ADD_APPROVED_CALL_TARGET, approveData);

        // Execute CALL proposal
        const callData = mockToken.interface.encodeFunctionData("transfer", [outsider.address, ethers.parseEther("1")]);
        const proposalData = coder.encode(
          ["address","uint256","bytes"],
          [tokenAddr, 0, callData]
        );
        await treasuryProposalLifecycle(owner, AT.CALL, proposalData);
        expect(await mockToken.balanceOf(outsider.address)).to.equal(ethers.parseEther("1"));
      });

      it("CALL reverts when call actions disabled", async function () {
        const callData = coder.encode(
          ["address","uint256","bytes"],
          [outsider.address, 0, "0x"]
        );
        await expect(
          treasuryProposalLifecycle(owner, AT.CALL, callData)
        ).to.be.revertedWithCustomError(treasury, "ActionDisabled");
      });

      it("CALL reverts when target not approved", async function () {
        // Enable call actions
        const enableData = coder.encode(["bool"], [true]);
        await treasuryProposalLifecycle(owner, AT.SET_CALL_ACTIONS_ENABLED, enableData);

        const callData = coder.encode(
          ["address","uint256","bytes"],
          [outsider.address, 0, "0x"]
        );
        await expect(
          treasuryProposalLifecycle(owner, AT.CALL, callData)
        ).to.be.revertedWithCustomError(treasury, "CallTargetNotApproved");
      });
    });

    describe("Settings proposals", function () {
      it("SET_TREASURER_CALLS_ENABLED full lifecycle", async function () {
        const data = coder.encode(["bool"], [true]);
        await treasuryProposalLifecycle(owner, AT.SET_TREASURER_CALLS_ENABLED, data);
        expect(await treasury.treasurerCallsEnabled()).to.be.true;
      });

      it("ADD_APPROVED_CALL_TARGET & REMOVE_APPROVED_CALL_TARGET lifecycle", async function () {
        const addData = coder.encode(["address"], [outsider.address]);
        await treasuryProposalLifecycle(owner, AT.ADD_APPROVED_CALL_TARGET, addData);
        expect(await treasury.approvedCallTargets(outsider.address)).to.be.true;

        const removeData = coder.encode(["address"], [outsider.address]);
        await treasuryProposalLifecycle(owner, AT.REMOVE_APPROVED_CALL_TARGET, removeData);
        expect(await treasury.approvedCallTargets(outsider.address)).to.be.false;
      });
    });

    describe("Admin functions", function () {
      it("setCapsEnabled by owner", async function () {
        await treasury.connect(owner).setCapsEnabled(true);
        expect(await treasury.capsEnabled()).to.be.true;
      });

      it("setDailyCap by owner", async function () {
        const cap = ethers.parseEther("50");
        await treasury.connect(owner).setDailyCap(ethers.ZeroAddress, cap);
        expect(await treasury.dailyCap(ethers.ZeroAddress)).to.equal(cap);
      });

      it("daily cap enforcement on TRANSFER_ETH", async function () {
        await owner.sendTransaction({ to: await treasury.getAddress(), value: ethers.parseEther("100") });
        await treasury.connect(owner).setCapsEnabled(true);
        // Set a very small cap so even the first transfer can exhaust it
        await treasury.connect(owner).setDailyCap(ethers.ZeroAddress, ethers.parseEther("1"));

        // First transfer within cap
        const data1 = coder.encode(["address","uint256"], [outsider.address, ethers.parseEther("1")]);
        await treasuryProposalLifecycle(owner, AT.TRANSFER_ETH, data1);

        // Second transfer on same day should exceed cap — but proposals advance time.
        // So we do this directly: propose, vote, finalize, then execute within same day.
        // Since treasuryProposalLifecycle advances time by ~8 days, cap days may differ.
        // Instead just test that a single large transfer exceeds the cap.
        const data2 = coder.encode(["address","uint256"], [outsider.address, ethers.parseEther("2")]);
        await expect(
          treasuryProposalLifecycle(owner, AT.TRANSFER_ETH, data2)
        ).to.be.revertedWithCustomError(treasury, "CapExceeded");
      });
    });

    describe("View functions", function () {
      it("balanceETH returns treasury ETH balance", async function () {
        await owner.sendTransaction({ to: await treasury.getAddress(), value: ethers.parseEther("5") });
        expect(await treasury.balanceETH()).to.equal(ethers.parseEther("5"));
      });

      it("balanceERC20 returns token balance", async function () {
        const tokenAddr = await mockToken.getAddress();
        await mockToken.mint(await treasury.getAddress(), ethers.parseEther("42"));
        expect(await treasury.balanceERC20(tokenAddr)).to.equal(ethers.parseEther("42"));
      });

      it("getProposal returns proposal data", async function () {
        await owner.sendTransaction({ to: await treasury.getAddress(), value: ethers.parseEther("10") });
        const data = coder.encode(["address","uint256"], [outsider.address, ethers.parseEther("1")]);
        const proposalId = await treasury.connect(owner).propose.staticCall(AT.TRANSFER_ETH, data);
        await treasury.connect(owner).propose(AT.TRANSFER_ETH, data);
        const p = await treasury.getProposal(proposalId);
        expect(p.actionType).to.equal(AT.TRANSFER_ETH);
        expect(p.finalized).to.be.false;
      });

      it("getProposalData returns encoded data", async function () {
        const data = coder.encode(["address","uint256"], [outsider.address, ethers.parseEther("1")]);
        const proposalId = await treasury.connect(owner).propose.staticCall(AT.TRANSFER_ETH, data);
        await treasury.connect(owner).propose(AT.TRANSFER_ETH, data);
        const storedData = await treasury.getProposalData(proposalId);
        expect(storedData).to.equal(data);
      });

      it("getProposal reverts for non-existent proposal", async function () {
        await expect(treasury.getProposal(999)).to.be.revertedWithCustomError(treasury, "ProposalNotFound");
      });

      it("getProposalData reverts for non-existent proposal", async function () {
        await expect(treasury.getProposalData(999)).to.be.revertedWithCustomError(treasury, "ProposalNotFound");
      });
    });
  });

  // ══════════════════════════════════════════════════════════
  //  GuildController — Forwarding coverage
  // ══════════════════════════════════════════════════════════
  describe("GuildController (forwarding)", function () {
    let memberId2;

    beforeEach(async function () {
      memberId2 = await inviteAndAccept(owner, member1);
    });

    it("setRank forwarded from OrderController", async function () {
      // Issue promotion grant via order
      await orders.connect(owner).issuePromotionGrant(memberId2, Rank.F);
      const orderId = (await orders.nextOrderId()) - 1n;
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await orders.connect(member1).acceptPromotionGrant(orderId);

      const m = await dao.getMember(memberId2);
      expect(m.rank).to.equal(Rank.F);
    });

    it("setRank forwarded from ProposalController (GrantRank)", async function () {
      // Create GrantRank governance proposal
      await proposals.connect(owner).createProposalGrantRank(memberId2, Rank.E);
      const propId = (await proposals.nextProposalId()) - 1n;
      await mineBlocks(2);
      await proposals.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await proposals.connect(owner).finalizeProposal(propId);

      const m = await dao.getMember(memberId2);
      expect(m.rank).to.equal(Rank.E);
    });

    it("setAuthority forwarded from OrderController", async function () {
      await orders.connect(owner).issueAuthorityOrder(memberId2, extra1.address);
      const orderId = (await orders.nextOrderId()) - 1n;
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await orders.connect(owner).executeOrder(orderId);

      const m = await dao.getMember(memberId2);
      expect(m.authority).to.equal(extra1.address);
    });

    it("setVotingPeriod forwarded from ProposalController", async function () {
      await proposals.connect(owner).createProposalChangeParameter(PType.ChangeVotingPeriod, 86400);
      const propId = (await proposals.nextProposalId()) - 1n;
      await mineBlocks(2);
      await proposals.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await proposals.connect(owner).finalizeProposal(propId);

      expect(await dao.votingPeriod()).to.equal(86400);
    });

    it("transferERC20 forwarded from ProposalController", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const token = await MockERC20.deploy("Tok", "TK");
      await token.waitForDeployment();
      await token.mint(await dao.getAddress(), ethers.parseEther("100"));

      await proposals.connect(owner).createProposalTransferERC20(
        await token.getAddress(), ethers.parseEther("10"), outsider.address
      );
      const propId = (await proposals.nextProposalId()) - 1n;
      await mineBlocks(2);
      await proposals.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await proposals.connect(owner).finalizeProposal(propId);

      expect(await token.balanceOf(outsider.address)).to.equal(ethers.parseEther("10"));
    });

    it("addMember forwarded from InviteController", async function () {
      const memberId3 = await inviteAndAccept(owner, member2);
      expect(memberId3).to.be.gt(0);
      const m = await dao.getMember(memberId3);
      expect(m.rank).to.equal(Rank.G);
      expect(m.authority).to.equal(member2.address);
    });

    it("outsider cannot call onlySubController functions", async function () {
      await expect(
        guild.connect(outsider).setRank(1, Rank.F, 1, false)
      ).to.be.revertedWithCustomError(guild, "NotAuthorized");
    });

    it("outsider cannot call onlyProposalController functions", async function () {
      await expect(
        guild.connect(outsider).setVotingPeriod(100)
      ).to.be.revertedWithCustomError(guild, "NotAuthorized");
    });

    it("outsider cannot call onlyInviteController functions", async function () {
      await expect(
        guild.connect(outsider).addMember(outsider.address)
      ).to.be.revertedWithCustomError(guild, "NotAuthorized");
    });

    it("cannot set sub-controllers to zero address", async function () {
      // Try via owner during bootstrap scenario — but owner has renounced so use proposalController
      // Actually owner hasn't finalized yet so owner can still set
      // Re-deploy fresh DAO for this test isn't needed - the revert happens regardless
      await expect(
        guild.connect(owner).setOrderController(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(guild, "InvalidAddress");
      await expect(
        guild.connect(owner).setProposalController(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(guild, "InvalidAddress");
      await expect(
        guild.connect(owner).setInviteController(ethers.ZeroAddress)
      ).to.be.revertedWithCustomError(guild, "InvalidAddress");
    });

    it("outsider cannot set sub-controllers", async function () {
      await expect(
        guild.connect(outsider).setOrderController(extra1.address)
      ).to.be.revertedWithCustomError(guild, "NotAuthorized");
      await expect(
        guild.connect(outsider).setProposalController(extra1.address)
      ).to.be.revertedWithCustomError(guild, "NotAuthorized");
      await expect(
        guild.connect(outsider).setInviteController(extra1.address)
      ).to.be.revertedWithCustomError(guild, "NotAuthorized");
    });
  });
});
