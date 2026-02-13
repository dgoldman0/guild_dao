// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RankedMembershipDAO} from "../../contracts/RankedMembershipDAO.sol";
import {FeeRouter}           from "../../contracts/FeeRouter.sol";
import "./GuildDeployHelper.sol";

/// @title FuzzFees — Property-based tests for fee payment, deactivation, &
///        epoch extension logic.
/// @dev   Ensures fee amounts are always correct, feePaidUntil extends by
///        exactly EPOCH, and deactivation timing respects gracePeriod.
contract FuzzFees is GuildDeployHelper {
    uint32 feePayerMemberId;

    function setUp() public {
        _deploySystem();

        // Configure fee system (via GuildController)
        vm.startPrank(address(guild));
        dao.setBaseFee(0.01 ether);
        dao.setFeeToken(address(0));            // ETH
        dao.setPayoutTreasury(address(treasury));
        dao.setGracePeriod(1 days);
        vm.stopPrank();

        feePayerMemberId = memberFId; // rank F, fee = baseFee * 2 = 0.02 ether
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Property: feeOfRank matches expected for every rank
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_feeOfRank_matchesBaseFeeTimesRankPower(uint8 rankIdx) public view {
        rankIdx = uint8(bound(rankIdx, 0, 9));
        RankedMembershipDAO.Rank r = RankedMembershipDAO.Rank(rankIdx);

        uint256 fee = dao.feeOfRank(r);
        uint256 expected = dao.baseFee() * (1 << rankIdx);
        assertEq(fee, expected, "Fee = baseFee * 2^rankIndex");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Property: paying fee extends feePaidUntil by exactly EPOCH
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_payFee_extendsExactlyOneEpoch(uint256 warpBefore) public {
        // Don't let the existing fee expiry pass (member starts with feePaidUntil=max
        // because they're bootstrap members). We need a non-bootstrap member.
        // Add a new member via invite to get a normal fee schedule.
        vm.prank(address(invites));
        guild.addMember(address(0xFEE1));
        uint32 newId = dao.memberIdByAuthority(address(0xFEE1));

        uint64 paidBefore = dao.feePaidUntil(newId);
        // paidBefore = block.timestamp + EPOCH (first epoch free)

        // Warp to some point before expiry so fee payment stacks
        warpBefore = bound(warpBefore, 0, uint256(dao.EPOCH()) - 1);
        vm.warp(block.timestamp + warpBefore);

        // Pay fee
        (,, RankedMembershipDAO.Rank rank,,) = dao.membersById(newId);
        uint256 fee = dao.feeOfRank(rank);
        vm.deal(address(this), fee);
        feeRouter.payMembershipFee{value: fee}(newId);

        uint64 paidAfter = dao.feePaidUntil(newId);
        assertEq(paidAfter, paidBefore + dao.EPOCH(), "Must extend by exactly EPOCH");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Property: paying fee when expired resets to now + EPOCH
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_payFee_whenExpired_resetsFromNow(uint256 extraWarp) public {
        // Create non-bootstrap member
        vm.prank(address(invites));
        guild.addMember(address(0xFEE2));
        uint32 newId = dao.memberIdByAuthority(address(0xFEE2));

        // Warp well past their expiry: EPOCH + grace + extra
        extraWarp = bound(extraWarp, 1, 365 days);
        uint256 totalWarp = uint256(dao.EPOCH()) + uint256(dao.gracePeriod()) + extraWarp + 1;
        vm.warp(block.timestamp + totalWarp);

        // Deactivate first (required: member must be expired)
        dao.deactivateMember(newId);
        assertFalse(dao.isMemberActive(newId));

        // Pay fee — should reactivate and set feePaidUntil = now + EPOCH
        (,, RankedMembershipDAO.Rank rank,,) = dao.membersById(newId);
        uint256 fee = dao.feeOfRank(rank);
        vm.deal(address(this), fee);
        feeRouter.payMembershipFee{value: fee}(newId);

        assertTrue(dao.isMemberActive(newId), "Must be reactivated");
        assertEq(
            dao.feePaidUntil(newId),
            uint64(block.timestamp) + dao.EPOCH(),
            "Expired payment resets to now + EPOCH"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Property: cannot deactivate member before expiry + grace
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_cannotDeactivate_beforeExpiry(uint256 warpSecs) public {
        // Create non-bootstrap member
        vm.prank(address(invites));
        guild.addMember(address(0xFEE3));
        uint32 newId = dao.memberIdByAuthority(address(0xFEE3));

        uint64 paidUntil = dao.feePaidUntil(newId);
        uint64 grace = dao.gracePeriod();
        uint256 deadline = uint256(paidUntil) + uint256(grace);

        // Warp to somewhere before the deadline
        warpSecs = bound(warpSecs, 0, deadline - block.timestamp);
        vm.warp(block.timestamp + warpSecs);

        vm.expectRevert(RankedMembershipDAO.MemberNotExpired.selector);
        dao.deactivateMember(newId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Property: can deactivate member after expiry + grace
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_canDeactivate_afterExpiry(uint256 extraSecs) public {
        vm.prank(address(invites));
        guild.addMember(address(0xFEE4));
        uint32 newId = dao.memberIdByAuthority(address(0xFEE4));

        uint64 paidUntil = dao.feePaidUntil(newId);
        uint64 grace = dao.gracePeriod();
        uint256 deadline = uint256(paidUntil) + uint256(grace);

        extraSecs = bound(extraSecs, 1, 365 days);
        vm.warp(deadline + extraSecs);

        dao.deactivateMember(newId);
        assertFalse(dao.isMemberActive(newId), "Member should be deactivated");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Property: bootstrap members (feePaidUntil = max) cannot be deactivated
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_bootstrapMember_neverExpires(uint256 warpSecs) public {
        // Cap warp so block.timestamp doesn't exceed 2^64 (which would overflow
        // the uint64 comparison in deactivateMember check)
        warpSecs = bound(warpSecs, 0, type(uint64).max - block.timestamp - 1);

        // Owner is bootstrap — feePaidUntil = type(uint64).max
        assertEq(dao.feePaidUntil(ownerMemberId), type(uint64).max);

        vm.warp(block.timestamp + warpSecs);

        vm.expectRevert(RankedMembershipDAO.MemberNotExpired.selector);
        dao.deactivateMember(ownerMemberId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Property: incorrect fee amount reverts
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_incorrectFeeAmount_reverts(uint256 wrongAmount) public {
        vm.prank(address(invites));
        guild.addMember(address(0xFEE5));
        uint32 newId = dao.memberIdByAuthority(address(0xFEE5));

        (,, RankedMembershipDAO.Rank rank,,) = dao.membersById(newId);
        uint256 correctFee = dao.feeOfRank(rank);
        vm.assume(wrongAmount != correctFee);

        vm.deal(address(this), wrongAmount);
        vm.expectRevert(FeeRouter.IncorrectFeeAmount.selector);
        feeRouter.payMembershipFee{value: wrongAmount}(newId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Property: ERC-20 fee path works
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_erc20FeePath_works(uint256 baseFee_) public {
        baseFee_ = bound(baseFee_, 1, 1e24);

        // Switch to ERC-20 fee mode
        vm.startPrank(address(guild));
        dao.setFeeToken(address(token));
        dao.setBaseFee(baseFee_);
        vm.stopPrank();

        vm.prank(address(invites));
        guild.addMember(address(0xFEE6));
        uint32 newId = dao.memberIdByAuthority(address(0xFEE6));

        (,, RankedMembershipDAO.Rank rank,,) = dao.membersById(newId);
        uint256 fee = dao.feeOfRank(rank);
        assertEq(fee, baseFee_ * 1, "Rank G fee = baseFee * 1");

        // Mint, approve, pay
        token.mint(address(this), fee);
        token.approve(address(feeRouter), fee);
        feeRouter.payMembershipFee(newId);

        assertEq(
            dao.feePaidUntil(newId),
            uint64(block.timestamp) + dao.EPOCH() + dao.EPOCH(),
            "Should stack: first free epoch + paid epoch"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Property: bootstrap member fee payment reverts
    // ═══════════════════════════════════════════════════════════════════════════

    function test_bootstrapMember_feePaymentReverts() public {
        vm.deal(address(this), 100 ether);
        // Owner is bootstrap with baseFee = 0.01 ether, rank SSS
        // fee = 0.01 * 512 = 5.12 ether
        uint256 fee = dao.feeOfRank(RankedMembershipDAO.Rank.SSS);

        vm.expectRevert(abi.encodeWithSignature("BootstrapMemberFeeExempt()"));
        feeRouter.payMembershipFee{value: fee}(ownerMemberId);
    }
}
