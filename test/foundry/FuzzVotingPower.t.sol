// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RankedMembershipDAO} from "../../contracts/RankedMembershipDAO.sol";
import {ActionTypes}         from "../../contracts/libraries/ActionTypes.sol";
import "./GuildDeployHelper.sol";

/// @title FuzzVotingPower — Property-based tests for voting power accounting.
/// @dev   Ensures totalVotingPower is always the exact sum of all member powers,
///        and that rank changes, activation/deactivation maintain the invariant.
contract FuzzVotingPower is GuildDeployHelper {
    function setUp() public {
        _deploySystem();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Invariant: totalVotingPower == Σ votingPowerOfMember(i) for all members
    // ═══════════════════════════════════════════════════════════════════════════

    function _sumAllMemberPower() internal view returns (uint224 total) {
        uint32 n = dao.nextMemberId();
        for (uint32 i = 1; i < n; i++) {
            total += dao.votingPowerOfMember(i);
        }
    }

    function _assertTotalPowerInvariant() internal view {
        uint224 reported = dao.totalVotingPower();
        uint224 computed = _sumAllMemberPower();
        assertEq(reported, computed, "Total power must equal sum of member powers");
    }

    // After setup: 4 bootstrap members (SSS, F, E, D) all active
    function test_initialTotalPowerInvariant() public view {
        _assertTotalPowerInvariant();
        // SSS=512, F=2, E=4, D=8 → 526
        assertEq(dao.totalVotingPower(), 526);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: addMember always increases total by votingPowerOfRank(G) = 1
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_addMember_increasesTotalByOne(address newAuth) public {
        vm.assume(newAuth != address(0));
        vm.assume(dao.memberIdByAuthority(newAuth) == 0);
        // Exclude known contract addresses
        vm.assume(newAuth != address(dao) && newAuth != address(guild));
        vm.assume(newAuth != address(orders) && newAuth != address(proposals));
        vm.assume(newAuth != address(invites) && newAuth != address(treasury));
        vm.assume(newAuth != address(treasurer) && newAuth != address(feeRouter));
        vm.assume(newAuth != address(token) && newAuth != address(nft));

        uint224 before_ = dao.totalVotingPower();

        // addMember goes through GuildController (only callable by InviteController)
        vm.prank(address(invites));
        guild.addMember(newAuth);

        uint224 after_ = dao.totalVotingPower();
        assertEq(after_, before_ + 1, "New member adds 1 power (rank G)");
        _assertTotalPowerInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: setRank adjusts total power correctly
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_setRank_adjustsTotalPower(uint8 newRankIdx) public {
        newRankIdx = uint8(bound(newRankIdx, 0, 9));
        RankedMembershipDAO.Rank newRank = RankedMembershipDAO.Rank(newRankIdx);

        uint32 targetId = memberFId;  // F member
        uint224 before_ = dao.totalVotingPower();
        uint224 oldPower = dao.votingPowerOfMember(targetId);
        uint224 newPower = dao.votingPowerOfRank(newRank);

        // setRank goes through GuildController → dao
        vm.prank(address(orders));
        guild.setRank(targetId, newRank, ownerMemberId, false);

        uint224 after_ = dao.totalVotingPower();
        if (newPower > oldPower) {
            assertEq(after_, before_ + (newPower - oldPower));
        } else {
            assertEq(after_, before_ - (oldPower - newPower));
        }
        _assertTotalPowerInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: deactivation zeroes member power, reduces total
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_deactivation_zeroesAndReduces(uint8 targetSel) public {
        // Pick one of the non-owner members (2, 3, or 4)
        targetSel = uint8(bound(targetSel, 0, 2));
        uint32 targetId = targetSel == 0 ? memberFId : (targetSel == 1 ? memberEId : memberDId);

        uint224 memberPow = dao.votingPowerOfMember(targetId);
        uint224 before_ = dao.totalVotingPower();

        // Deactivate via controller (governance override)
        vm.prank(address(proposals));
        guild.setMemberActive(targetId, false);

        assertEq(dao.votingPowerOfMember(targetId), 0, "Deactivated member has 0 power");
        assertEq(dao.totalVotingPower(), before_ - memberPow, "Total reduced by member power");
        _assertTotalPowerInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: reactivation restores member power
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_reactivation_restoresPower(uint8 targetSel) public {
        targetSel = uint8(bound(targetSel, 0, 2));
        uint32 targetId = targetSel == 0 ? memberFId : (targetSel == 1 ? memberEId : memberDId);

        // Deactivate first
        vm.prank(address(proposals));
        guild.setMemberActive(targetId, false);

        (,, RankedMembershipDAO.Rank rank,,) = dao.membersById(targetId);
        uint224 expectedPow = dao.votingPowerOfRank(rank);
        uint224 before_ = dao.totalVotingPower();

        // Reactivate
        vm.prank(address(proposals));
        guild.setMemberActive(targetId, true);

        assertEq(dao.votingPowerOfMember(targetId), expectedPow, "Reactivated power matches rank");
        assertEq(dao.totalVotingPower(), before_ + expectedPow, "Total increased by rank power");
        _assertTotalPowerInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: rank change on inactive member does NOT change total
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_rankChange_whileInactive_noTotalChange(uint8 newRankIdx) public {
        newRankIdx = uint8(bound(newRankIdx, 0, 9));

        // Deactivate member F
        vm.prank(address(proposals));
        guild.setMemberActive(memberFId, false);

        uint224 totalBefore = dao.totalVotingPower();

        // Change rank — should NOT affect total (member is inactive)
        vm.prank(address(orders));
        guild.setRank(memberFId, RankedMembershipDAO.Rank(newRankIdx), ownerMemberId, false);

        assertEq(dao.totalVotingPower(), totalBefore, "Inactive rank change must not affect total");
        assertEq(dao.votingPowerOfMember(memberFId), 0, "Inactive member has 0 power");
        _assertTotalPowerInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: sequence of rank changes maintains invariant
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_multipleRankChanges_invariantHolds(
        uint8 r1, uint8 r2, uint8 r3
    ) public {
        r1 = uint8(bound(r1, 0, 9));
        r2 = uint8(bound(r2, 0, 9));
        r3 = uint8(bound(r3, 0, 9));

        vm.startPrank(address(orders));
        guild.setRank(memberFId, RankedMembershipDAO.Rank(r1), ownerMemberId, false);
        guild.setRank(memberEId, RankedMembershipDAO.Rank(r2), ownerMemberId, false);
        guild.setRank(memberDId, RankedMembershipDAO.Rank(r3), ownerMemberId, false);
        vm.stopPrank();

        _assertTotalPowerInvariant();
    }
}
