// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RankedMembershipDAO} from "../../contracts/RankedMembershipDAO.sol";
import "./GuildDeployHelper.sol";

/// @title FuzzRankMath — Property-based tests for rank math and fee calculations.
/// @dev   Pure function properties that must hold for ALL inputs.
contract FuzzRankMath is GuildDeployHelper {
    function setUp() public {
        _deploySystem();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  votingPowerOfRank:  power(r) == 2^rankIndex(r)
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_votingPowerOfRank_isPowerOfTwo(uint8 rankIdx) public view {
        rankIdx = uint8(bound(rankIdx, 0, 9)); // 10 ranks: G(0) .. SSS(9)
        RankedMembershipDAO.Rank r = RankedMembershipDAO.Rank(rankIdx);
        uint224 power = dao.votingPowerOfRank(r);
        assertEq(power, uint224(1 << rankIdx), "Power must be 2^rankIndex");
    }

    function testFuzz_votingPowerOfRank_monotonicIncrease(uint8 a, uint8 b) public view {
        a = uint8(bound(a, 0, 9));
        b = uint8(bound(b, 0, 9));
        uint224 pa = dao.votingPowerOfRank(RankedMembershipDAO.Rank(a));
        uint224 pb = dao.votingPowerOfRank(RankedMembershipDAO.Rank(b));
        if (a < b) {
            assertLt(pa, pb, "Higher rank must have more power");
        } else if (a == b) {
            assertEq(pa, pb, "Same rank must have same power");
        } else {
            assertGt(pa, pb, "Lower rank must have less power");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  inviteAllowanceOfRank:  G=0, F+=2^(idx-1)
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_inviteAllowance_formula(uint8 rankIdx) public view {
        rankIdx = uint8(bound(rankIdx, 0, 9));
        RankedMembershipDAO.Rank r = RankedMembershipDAO.Rank(rankIdx);
        uint16 allowance = dao.inviteAllowanceOfRank(r);
        if (rankIdx == 0) {
            assertEq(allowance, 0, "Rank G cannot invite");
        } else {
            assertEq(allowance, uint16(1 << (rankIdx - 1)),
                "F+ invite = 2^(rankIndex-1)");
        }
    }

    function testFuzz_inviteAllowance_monotonic(uint8 a, uint8 b) public view {
        a = uint8(bound(a, 1, 9)); // F+
        b = uint8(bound(b, 1, 9));
        uint16 ia = dao.inviteAllowanceOfRank(RankedMembershipDAO.Rank(a));
        uint16 ib = dao.inviteAllowanceOfRank(RankedMembershipDAO.Rank(b));
        if (a < b) assertLt(ia, ib);
        else if (a > b) assertGt(ia, ib);
        else assertEq(ia, ib);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  proposalLimitOfRank:  G=0, F=1, E=2 ... SSS=9
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_proposalLimit_formula(uint8 rankIdx) public view {
        rankIdx = uint8(bound(rankIdx, 0, 9));
        RankedMembershipDAO.Rank r = RankedMembershipDAO.Rank(rankIdx);
        uint8 limit = dao.proposalLimitOfRank(r);
        if (rankIdx == 0) {
            assertEq(limit, 0, "Rank G has no proposal rights");
        } else {
            assertEq(limit, uint8(1 + (rankIdx - 1)), "F+ limit = 1 + (rankIndex - 1)");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  orderLimitOfRank:  G,F=0, E=1, D=2, C=4, ...
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_orderLimit_formula(uint8 rankIdx) public view {
        rankIdx = uint8(bound(rankIdx, 0, 9));
        RankedMembershipDAO.Rank r = RankedMembershipDAO.Rank(rankIdx);
        uint8 limit = dao.orderLimitOfRank(r);
        if (rankIdx < 2) {
            assertEq(limit, 0, "G, F cannot issue orders");
        } else {
            assertEq(limit, uint8(1 << (rankIdx - 2)),
                "E+ limit = 2^(rankIndex - 2)");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  feeOfRank:  baseFee * 2^rankIndex  — no overflow for reasonable baseFee
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_feeOfRank_formula(uint8 rankIdx, uint256 baseFee) public {
        rankIdx = uint8(bound(rankIdx, 0, 9));
        // Limit baseFee to a reasonable range where multiplication won't overflow:
        // max rank SSS = 2^9 = 512, so baseFee * 512 must fit in uint256.
        // type(uint256).max / 512 is huge, but let's cap at 10^30 (well above any token)
        baseFee = bound(baseFee, 0, 1e30);

        // Can't call setBaseFee without being controller — use prank
        // The DAO is owned by nobody (ownership renounced), but controller can set baseFee
        vm.prank(address(guild));
        dao.setBaseFee(baseFee);

        RankedMembershipDAO.Rank r = RankedMembershipDAO.Rank(rankIdx);
        uint256 fee = dao.feeOfRank(r);
        assertEq(fee, baseFee * (1 << rankIdx), "Fee = baseFee * 2^rank");
    }

    function testFuzz_feeOfRank_rankOrdering(uint8 a, uint8 b, uint256 baseFee) public {
        a = uint8(bound(a, 0, 9));
        b = uint8(bound(b, 0, 9));
        baseFee = bound(baseFee, 1, 1e30); // non-zero

        vm.prank(address(guild));
        dao.setBaseFee(baseFee);

        uint256 fa = dao.feeOfRank(RankedMembershipDAO.Rank(a));
        uint256 fb = dao.feeOfRank(RankedMembershipDAO.Rank(b));

        if (a < b) assertLt(fa, fb, "Higher rank pays more");
        else if (a == b) assertEq(fa, fb);
        else assertGt(fa, fb);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Cross-property: votingPower(r) exactly doubles each rank step
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_votingPower_doublesPerRank(uint8 rankIdx) public view {
        rankIdx = uint8(bound(rankIdx, 1, 9)); // F through SSS
        uint224 prev = dao.votingPowerOfRank(RankedMembershipDAO.Rank(rankIdx - 1));
        uint224 curr = dao.votingPowerOfRank(RankedMembershipDAO.Rank(rankIdx));
        assertEq(curr, prev * 2, "Power must exactly double each rank");
    }
}
