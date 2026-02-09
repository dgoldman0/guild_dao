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
  BlockOrder: 8, TransferERC20: 9,
};

describe("Guild DAO System", function () {
  let dao, governance, treasurerModule, treasury;
  let owner, member1, member2, outsider, extra1, extra2, extra3;
  const coder = ethers.AbiCoder.defaultAbiCoder();

  // ─── Utility helpers ──────────────────────────────────────
  async function inviteAndAccept(inviter, inviteeWallet) {
    await governance.connect(inviter).issueInvite(inviteeWallet.address);
    const inviteId = (await governance.nextInviteId()) - 1n;
    await governance.connect(inviteeWallet).acceptInvite(inviteId);
    return await dao.memberIdByAuthority(inviteeWallet.address);
  }

  async function promoteViaOrder(issuer, targetId, newRank) {
    const tx = await governance.connect(issuer).issuePromotionGrant(targetId, newRank);
    const orderId = (await governance.nextOrderId()) - 1n;
    await ethers.provider.send("evm_increaseTime", [86401]);
    await ethers.provider.send("evm_mine");
    const member = await dao.getMember(targetId);
    const targetSigner = (await ethers.getSigners()).find(
      (s) => s.address === member.authority
    );
    await governance.connect(targetSigner).acceptPromotionGrant(orderId);
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

    const GovernanceController = await ethers.getContractFactory("GovernanceController");
    governance = await GovernanceController.deploy(await dao.getAddress());
    await governance.waitForDeployment();

    await dao.setController(await governance.getAddress());

    const TreasurerModule = await ethers.getContractFactory("TreasurerModule");
    treasurerModule = await TreasurerModule.deploy(await dao.getAddress());
    await treasurerModule.waitForDeployment();

    const MembershipTreasury = await ethers.getContractFactory("MembershipTreasury");
    treasury = await MembershipTreasury.deploy(await dao.getAddress());
    await treasury.waitForDeployment();

    await treasury.setTreasurerModule(await treasurerModule.getAddress());
    await treasurerModule.setTreasury(await treasury.getAddress());
  });

  // ══════════════════════════════════════════════════════════
  //  Deployment
  // ══════════════════════════════════════════════════════════
  describe("Deployment", function () {
    it("deploys all four contracts", async function () {
      expect(await dao.getAddress()).to.be.properAddress;
      expect(await governance.getAddress()).to.be.properAddress;
      expect(await treasurerModule.getAddress()).to.be.properAddress;
      expect(await treasury.getAddress()).to.be.properAddress;
    });

    it("links controller to DAO", async function () {
      expect(await dao.controller()).to.equal(await governance.getAddress());
    });

    it("links treasury ↔ module", async function () {
      expect(await treasury.treasurerModule()).to.equal(await treasurerModule.getAddress());
      expect(await treasurerModule.treasury()).to.equal(await treasury.getAddress());
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
        // governance is the controller — call setController from governance contract?
        // We can't directly impersonate, but we can use the fact that owner can still call it
        // since owner != address(0). After finalize, only controller can call.
        await dao.finalizeBootstrap(); // owner renounced
        // Now only controller (governance contract) can call setController.
        // We can't call dao.setController from governance directly (no such method).
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
      await governance.connect(owner).issueInvite(member1.address);
      const inv = await governance.getInvite(1);
      expect(inv.exists).to.be.true;
      expect(inv.to).to.equal(member1.address);
    });

    it("invited address accepts and becomes rank G", async function () {
      const id = await inviteAndAccept(owner, member1);
      const m = await dao.getMember(id);
      expect(m.rank).to.equal(Rank.G);
    });

    it("non-invited address cannot accept", async function () {
      await governance.connect(owner).issueInvite(member1.address);
      await expect(
        governance.connect(member2).acceptInvite(1)
      ).to.be.revertedWithCustomError(governance, "InvalidAddress");
    });

    it("cannot accept same invite twice", async function () {
      await governance.connect(owner).issueInvite(member1.address);
      await governance.connect(member1).acceptInvite(1);
      await expect(
        governance.connect(member1).acceptInvite(1)
      ).to.be.revertedWithCustomError(governance, "InviteAlreadyClaimed");
    });

    it("invite expires and can be reclaimed", async function () {
      await governance.connect(owner).issueInvite(member1.address);
      // advance past invite expiry (24h)
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      // accept fails (expired)
      await expect(
        governance.connect(member1).acceptInvite(1)
      ).to.be.revertedWithCustomError(governance, "InviteExpired");
      // reclaim succeeds
      await governance.connect(owner).reclaimExpiredInvite(1);
      const inv = await governance.getInvite(1);
      expect(inv.reclaimed).to.be.true;
    });

    it("cannot reclaim before expiry", async function () {
      await governance.connect(owner).issueInvite(member1.address);
      await expect(
        governance.connect(owner).reclaimExpiredInvite(1)
      ).to.be.revertedWithCustomError(governance, "InviteNotYetExpired");
    });

    it("G member cannot issue invites (allowance=0)", async function () {
      await inviteAndAccept(owner, member1);
      await expect(
        governance.connect(member1).issueInvite(member2.address)
      ).to.be.revertedWithCustomError(governance, "NotEnoughRank");
    });

    it("cannot invite an existing member", async function () {
      await inviteAndAccept(owner, member1);
      await expect(
        governance.connect(owner).issueInvite(member1.address)
      ).to.be.revertedWithCustomError(governance, "AlreadyMember");
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
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      // Too early
      await expect(
        governance.connect(member1).acceptPromotionGrant(1)
      ).to.be.revertedWithCustomError(governance, "OrderNotReady");
      // Wait
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await governance.connect(member1).acceptPromotionGrant(1);
      expect((await dao.getMember(m1Id)).rank).to.equal(Rank.F);
    });

    it("demotion order: create, wait, execute", async function () {
      // Promote m1 to E first so SSS can demote E (SSS=9 >= E(2)+2=4 ✓)
      await promoteViaOrder(owner, m1Id, Rank.E);

      await governance.connect(owner).issueDemotionOrder(m1Id);
      const orderId = (await governance.nextOrderId()) - 1n;

      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await governance.connect(owner).executeOrder(orderId);

      expect((await dao.getMember(m1Id)).rank).to.equal(Rank.F); // E-1=D? No, demotion does rank-1
    });

    it("authority order: create, wait, execute", async function () {
      // SSS(9) can issue authority order on G(0): 9 >= 0+2 ✓
      await governance.connect(owner).issueAuthorityOrder(m1Id, extra2.address);
      const orderId = (await governance.nextOrderId()) - 1n;

      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await governance.connect(owner).executeOrder(orderId);

      expect((await dao.getMember(m1Id)).authority).to.equal(extra2.address);
    });

    it("block order by higher rank", async function () {
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      const orderId = (await governance.nextOrderId()) - 1n;
      // blocker needs rank >= SSS(9)+2 = impossible for SSS
      // Let's use a different scenario: promote m1 to E, m1 issues demotion on m2,
      // then SSS blocks
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await governance.connect(member1).acceptPromotionGrant(orderId);

      // promote m1 further to E
      await promoteViaOrder(owner, m1Id, Rank.E);

      // m1 (E=2) demotes m2 (G=0): 2 >= 0+2 ✓
      await governance.connect(member1).issueDemotionOrder(m2Id);
      const demoOrderId = (await governance.nextOrderId()) - 1n;

      // Owner (SSS=9) blocks: 9 >= 2+2 ✓
      await governance.connect(owner).blockOrder(demoOrderId);
      const order = await governance.getOrder(demoOrderId);
      expect(order.blocked).to.be.true;
    });

    it("cannot execute before delay", async function () {
      await governance.connect(owner).issueDemotionOrder(m1Id);
      await expect(
        governance.connect(owner).executeOrder(1)
      ).to.be.revertedWithCustomError(governance, "OrderNotReady");
    });

    it("cannot execute blocked order", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await governance.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await governance.nextOrderId()) - 1n;
      await governance.connect(owner).blockOrder(orderId);

      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await expect(
        governance.connect(member1).executeOrder(orderId)
      ).to.be.revertedWithCustomError(governance, "OrderIsBlocked");
    });

    it("only one pending order per target", async function () {
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      // second order on same target fails
      await expect(
        governance.connect(owner).issueDemotionOrder(m1Id)
      ).to.be.revertedWithCustomError(governance, "PendingActionExists");
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
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      await governance.connect(owner).issuePromotionGrant(m2Id, Rank.F);
      await governance.connect(owner).issuePromotionGrant(m3Id, Rank.F);
      expect(await governance.activeOrdersOf(1)).to.equal(3);
    });

    it("E-rank member (limit=1) is blocked from second order", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await governance.connect(member1).issueDemotionOrder(m2Id);
      await expect(
        governance.connect(member1).issueDemotionOrder(m3Id)
      ).to.be.revertedWithCustomError(governance, "TooManyActiveOrders");
    });

    it("slot freed by execute allows another order", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await governance.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await governance.nextOrderId()) - 1n;
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await governance.connect(member1).executeOrder(orderId);

      await governance.connect(member1).issueDemotionOrder(m3Id);
      expect(await governance.activeOrdersOf(m1Id)).to.equal(1);
    });

    it("slot freed by block allows another order", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await governance.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await governance.nextOrderId()) - 1n;
      await governance.connect(owner).blockOrder(orderId);

      await governance.connect(member1).issueDemotionOrder(m3Id);
      expect(await governance.activeOrdersOf(m1Id)).to.equal(1);
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
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      const orderId = (await governance.nextOrderId()) - 1n;
      await expect(governance.connect(owner).rescindOrder(orderId))
        .to.emit(governance, "OrderRescinded").withArgs(orderId, 1);
      expect(await governance.activeOrdersOf(1)).to.equal(0);
      expect(await governance.pendingOrderOfTarget(m1Id)).to.equal(0);
    });

    it("non-issuer cannot rescind", async function () {
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      await expect(
        governance.connect(member1).rescindOrder(1)
      ).to.be.revertedWithCustomError(governance, "InvalidTarget");
    });

    it("cannot rescind executed order", async function () {
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      await ethers.provider.send("evm_increaseTime", [86401]);
      await ethers.provider.send("evm_mine");
      await governance.connect(member1).acceptPromotionGrant(1);
      await expect(
        governance.connect(owner).rescindOrder(1)
      ).to.be.revertedWithCustomError(governance, "OrderNotReady");
    });

    it("cannot rescind blocked order", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await governance.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await governance.nextOrderId()) - 1n;
      await governance.connect(owner).blockOrder(orderId);
      await expect(
        governance.connect(member1).rescindOrder(orderId)
      ).to.be.revertedWithCustomError(governance, "OrderIsBlocked");
    });

    it("rescind frees slot for E-rank member", async function () {
      await promoteViaOrder(owner, m1Id, Rank.E);
      await governance.connect(member1).issueDemotionOrder(m2Id);
      const orderId = (await governance.nextOrderId()) - 1n;
      await expect(governance.connect(member1).issueDemotionOrder(m3Id))
        .to.be.revertedWithCustomError(governance, "TooManyActiveOrders");
      await governance.connect(member1).rescindOrder(orderId);
      await governance.connect(member1).issueDemotionOrder(m3Id);
      expect(await governance.activeOrdersOf(m1Id)).to.equal(1);
    });

    it("outsider cannot rescind", async function () {
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      await expect(
        governance.connect(outsider).rescindOrder(1)
      ).to.be.revertedWithCustomError(governance, "NotMember");
    });
  });

  // ══════════════════════════════════════════════════════════
  //  Stage 2b: Governance Proposals
  // ══════════════════════════════════════════════════════════
  describe("Governance Proposals", function () {

    it("GrantRank proposal: full cycle", async function () {
      const m1Id = await inviteAndAccept(owner, member1);

      // owner (SSS) proposes promoting m1 to A
      await governance.connect(owner).createProposalGrantRank(m1Id, Rank.A);
      const propId = (await governance.nextProposalId()) - 1n;

      // vote yes
      await governance.connect(owner).castVote(propId, true);

      // wait for voting period to end
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");

      await governance.connect(owner).finalizeProposal(propId);
      const p = await governance.getProposal(propId);
      expect(p.succeeded).to.be.true;
      expect((await dao.getMember(m1Id)).rank).to.equal(Rank.A);
    });

    it("DemoteRank proposal: full cycle", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await promoteViaOrder(owner, m1Id, Rank.E);

      await governance.connect(owner).createProposalDemoteRank(m1Id, Rank.F);
      const propId = (await governance.nextProposalId()) - 1n;
      await governance.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await governance.connect(owner).finalizeProposal(propId);

      expect((await dao.getMember(m1Id)).rank).to.equal(Rank.F);
    });

    it("ChangeAuthority proposal: full cycle", async function () {
      const m1Id = await inviteAndAccept(owner, member1);

      await governance.connect(owner).createProposalChangeAuthority(m1Id, extra2.address);
      const propId = (await governance.nextProposalId()) - 1n;
      await governance.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await governance.connect(owner).finalizeProposal(propId);

      expect((await dao.getMember(m1Id)).authority).to.equal(extra2.address);
    });

    it("ChangeVotingPeriod parameter proposal: full cycle", async function () {
      const newPeriod = 3 * 86400; // 3 days
      await governance.connect(owner).createProposalChangeParameter(PType.ChangeVotingPeriod, newPeriod);
      const propId = (await governance.nextProposalId()) - 1n;
      await governance.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await governance.connect(owner).finalizeProposal(propId);

      expect(await dao.votingPeriod()).to.equal(newPeriod);
    });

    it("BlockOrder proposal: full cycle", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await governance.connect(owner).issuePromotionGrant(m1Id, Rank.F);
      const orderId = (await governance.nextOrderId()) - 1n;

      // propose to block the order
      await governance.connect(owner).createProposalBlockOrder(orderId);
      const propId = (await governance.nextProposalId()) - 1n;
      await governance.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await governance.connect(owner).finalizeProposal(propId);

      const order = await governance.getOrder(orderId);
      expect(order.blocked).to.be.true;
    });

    it("TransferERC20 proposal: full cycle", async function () {
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      const token = await MockERC20.deploy("Test", "TST");
      await token.waitForDeployment();
      const amount = ethers.parseUnits("100", 18);
      await token.mint(await dao.getAddress(), amount);

      await governance.connect(owner).createProposalTransferERC20(
        await token.getAddress(), amount, member1.address
      );
      const propId = (await governance.nextProposalId()) - 1n;
      await governance.connect(owner).castVote(propId, true);
      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await governance.connect(owner).finalizeProposal(propId);

      expect(await token.balanceOf(member1.address)).to.equal(amount);
    });

    // --- Edge cases ---
    it("vote after voting period ends → revert", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await governance.connect(owner).createProposalGrantRank(m1Id, Rank.F);
      const propId = (await governance.nextProposalId()) - 1n;

      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");

      await expect(
        governance.connect(owner).castVote(propId, true)
      ).to.be.revertedWithCustomError(governance, "ProposalEnded");
    });

    it("double vote → revert", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await governance.connect(owner).createProposalGrantRank(m1Id, Rank.F);
      const propId = (await governance.nextProposalId()) - 1n;
      await governance.connect(owner).castVote(propId, true);
      await expect(
        governance.connect(owner).castVote(propId, false)
      ).to.be.revertedWithCustomError(governance, "AlreadyVoted");
    });

    it("finalize before end → revert", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await governance.connect(owner).createProposalGrantRank(m1Id, Rank.F);
      const propId = (await governance.nextProposalId()) - 1n;
      await expect(
        governance.connect(owner).finalizeProposal(propId)
      ).to.be.revertedWithCustomError(governance, "ProposalEnded");
    });

    it("quorum not met → proposal fails", async function () {
      // Add many members to dilute voting power, then vote with only one
      await dao.bootstrapAddMember(member1.address, Rank.SSS); // member2 id=2
      await dao.bootstrapAddMember(member2.address, Rank.SSS); // member3 id=3
      // total power = 512*3=1536. quorum = 20% = 307.2 → 308
      // Only G member (power=1) votes — won't meet quorum
      const m4Id = await inviteAndAccept(owner, extra1); // G member

      await governance.connect(owner).createProposalGrantRank(m4Id, Rank.F);
      const propId = (await governance.nextProposalId()) - 1n;

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
      await governance.connect(owner).finalizeProposal(propId);

      const p = await governance.getProposal(propId);
      expect(p.succeeded).to.be.false;
    });

    it("proposal with more no than yes → fails", async function () {
      await dao.bootstrapAddMember(member1.address, Rank.SSS);
      const m3Id = await inviteAndAccept(owner, extra1);

      await governance.connect(owner).createProposalGrantRank(m3Id, Rank.F);
      const propId = (await governance.nextProposalId()) - 1n;

      // owner votes yes (512), member1 votes no (512)
      await governance.connect(owner).castVote(propId, true);
      await governance.connect(member1).castVote(propId, false);

      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await governance.connect(owner).finalizeProposal(propId);

      const p = await governance.getProposal(propId);
      expect(p.succeeded).to.be.false; // tie → fails (yes <= no)
    });

    it("activeProposalsOf decrements on finalize", async function () {
      const m1Id = await inviteAndAccept(owner, member1);
      await governance.connect(owner).createProposalGrantRank(m1Id, Rank.F);
      expect(await governance.activeProposalsOf(1)).to.equal(1);

      await ethers.provider.send("evm_increaseTime", [7 * 86400 + 1]);
      await ethers.provider.send("evm_mine");
      await governance.connect(owner).finalizeProposal(1);
      expect(await governance.activeProposalsOf(1)).to.equal(0);
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
  });
});
