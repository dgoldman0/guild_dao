// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RankedMembershipDAO} from "../../contracts/RankedMembershipDAO.sol";
import {TreasurerModule}     from "../../contracts/TreasurerModule.sol";
import {ActionTypes}         from "../../contracts/libraries/ActionTypes.sol";
import "./GuildDeployHelper.sol";

/// @title FuzzTreasury — Property-based tests for treasury spending limits & caps.
/// @dev   CRITICAL: ensures spending limits can never be exceeded, daily caps
///        are enforced, and period resets work correctly.
contract FuzzTreasury is GuildDeployHelper {
    uint32  treasurerMemberId;
    address treasurerAddr;

    function setUp() public {
        _deploySystem();

        treasurerMemberId = memberDId;    // rank D, power = 8
        treasurerAddr     = memberD;

        // Fund treasury with 10000 ETH + 10M tokens
        _fundTreasuryETH(10_000 ether);
        _fundTreasuryToken(10_000_000e18);

        // Add memberD as member-based treasurer via governance
        //   baseLim = 1 ether, limPerRank = 0.1 ether, period = 1 day, minRank = G
        _passAndExecuteProposal(
            ActionTypes.ADD_MEMBER_TREASURER,
            abi.encode(treasurerMemberId, 1 ether, 0.1 ether, uint64(1 days), uint8(0))
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Property: member-based spending limit = baseLim + limPerRank × power
    // ═══════════════════════════════════════════════════════════════════════════

    function test_memberTreasurer_limitCalculation() public view {
        // D rank = power 8. limit = 1 ether + 0.1 ether * 8 = 1.8 ether
        uint256 remaining = treasurer.getTreasurerRemainingLimit(treasurerAddr);
        assertEq(remaining, 1.8 ether, "Limit = base + perRank*power");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: spending never exceeds computed limit
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_memberSpending_cannotExceedLimit(uint256 amount) public {
        uint256 limit = 1.8 ether; // base(1) + perRank(0.1) * power(8)
        amount = bound(amount, 1, 100 ether);

        if (amount <= limit) {
            vm.prank(treasurerAddr);
            treasurer.treasurerSpendETH(outsider, amount);

            // Remaining must be correctly reduced
            uint256 remaining = treasurer.getTreasurerRemainingLimit(treasurerAddr);
            assertEq(remaining, limit - amount, "Remaining = limit - spent");
        } else {
            vm.prank(treasurerAddr);
            vm.expectRevert(TreasurerModule.TreasurerSpendingLimitExceeded.selector);
            treasurer.treasurerSpendETH(outsider, amount);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: multiple spends in same period accumulate
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_multipleSpends_accumulate(uint256 a, uint256 b) public {
        uint256 limit = 1.8 ether;
        a = bound(a, 1 wei, limit);
        b = bound(b, 1 wei, limit);

        vm.startPrank(treasurerAddr);

        // First spend should succeed
        treasurer.treasurerSpendETH(outsider, a);

        if (a + b <= limit) {
            // Second spend should succeed
            treasurer.treasurerSpendETH(outsider, b);
            uint256 remaining = treasurer.getTreasurerRemainingLimit(treasurerAddr);
            assertEq(remaining, limit - a - b, "Remaining = limit - a - b");
        } else {
            // Second spend should revert
            vm.expectRevert(TreasurerModule.TreasurerSpendingLimitExceeded.selector);
            treasurer.treasurerSpendETH(outsider, b);
        }

        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: period reset restores full limit
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_periodReset_restoresLimit(uint256 amount, uint256 warpSecs) public {
        uint256 limit = 1.8 ether;
        amount = bound(amount, 1 wei, limit);
        // Warp at least 1 full period (1 day) after spending
        warpSecs = bound(warpSecs, 1 days, 30 days);

        // Spend some
        vm.prank(treasurerAddr);
        treasurer.treasurerSpendETH(outsider, amount);

        // Advance past period
        vm.warp(block.timestamp + warpSecs);

        // Full limit should be available again
        uint256 remaining = treasurer.getTreasurerRemainingLimit(treasurerAddr);
        assertEq(remaining, limit, "After period reset, full limit available");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: spending limit scales with rank (rank promotion)
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_spendingLimit_scalesWithRank(uint8 newRankIdx) public {
        newRankIdx = uint8(bound(newRankIdx, 0, 9));
        RankedMembershipDAO.Rank newRank = RankedMembershipDAO.Rank(newRankIdx);

        // Promote/demote the treasurer member
        vm.prank(address(orders));
        guild.setRank(treasurerMemberId, newRank, ownerMemberId, false);

        uint224 newPower = dao.votingPowerOfRank(newRank);
        uint256 expectedLimit = 1 ether + 0.1 ether * uint256(newPower);

        // Need to warp past any spending period to get clean view
        vm.warp(block.timestamp + 2 days);

        uint256 remaining = treasurer.getTreasurerRemainingLimit(treasurerAddr);

        // If rank < minRank (G=0), treasurer is still valid since minRank=G
        // So limit should always match the formula
        assertEq(remaining, expectedLimit, "Limit must scale with rank power");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: address-based treasurer has fixed limit (no rank scaling)
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_addressTreasurer_fixedLimit(uint256 baseLim) public {
        baseLim = bound(baseLim, 1, 10_000 ether);  // within MAX_SPENDING_LIMIT

        address addrTreasurer = address(0xADD1);

        // Add address-based treasurer
        _passAndExecuteProposal(
            ActionTypes.ADD_ADDRESS_TREASURER,
            abi.encode(addrTreasurer, baseLim, uint64(1 days))
        );

        uint256 remaining = treasurer.getTreasurerRemainingLimit(addrTreasurer);
        assertEq(remaining, baseLim, "Address treasurer has flat limit");

        // Spending reduces limit
        if (baseLim >= 1 wei) {
            uint256 spend = bound(baseLim, 1, baseLim);
            vm.prank(addrTreasurer);
            treasurer.treasurerSpendETH(outsider, spend);
            remaining = treasurer.getTreasurerRemainingLimit(addrTreasurer);
            assertEq(remaining, baseLim - spend, "Remaining correctly reduced");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: ERC-20 spending respects token-specific config
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_tokenSpecificLimit(uint256 tokenLimit, uint256 amount) public {
        tokenLimit = bound(tokenLimit, 1, 1_000_000e18);
        amount = bound(amount, 1, 2_000_000e18);

        // Set token-specific limit for the member treasurer
        _passAndExecuteProposal(
            ActionTypes.SET_MEMBER_TOKEN_CONFIG,
            abi.encode(treasurerMemberId, address(token), tokenLimit, uint256(0))
        );

        // Token limit = tokenLimit + 0*power = tokenLimit
        if (amount <= tokenLimit) {
            vm.prank(treasurerAddr);
            treasurer.treasurerSpendERC20(address(token), outsider, amount);
        } else {
            vm.prank(treasurerAddr);
            vm.expectRevert(TreasurerModule.TreasurerSpendingLimitExceeded.selector);
            treasurer.treasurerSpendERC20(address(token), outsider, amount);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: daily caps on treasury proposals
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_dailyCap_enforced(uint256 cap, uint256 spendAmount) public {
        cap = bound(cap, 1 wei, 100 ether);
        spendAmount = bound(spendAmount, 1 wei, 200 ether);

        // Enable caps and set ETH daily cap
        treasury.setCapsEnabled(true);
        treasury.setDailyCap(address(0), cap);

        // Propose ETH transfer
        uint64 pid = treasury.propose(
            ActionTypes.TRANSFER_ETH,
            abi.encode(outsider, spendAmount)
        );

        // Vote and finalize
        vm.roll(block.number + 2);
        treasury.castVote(pid, true);
        vm.warp(block.timestamp + dao.votingPeriod() + 1);
        treasury.finalize(pid);
        vm.warp(block.timestamp + dao.executionDelay() + 1);

        if (spendAmount <= cap) {
            treasury.execute(pid);
        } else {
            vm.expectRevert(MembershipTreasury.CapExceeded.selector);
            treasury.execute(pid);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Fuzz: non-treasurer cannot spend
    // ═══════════════════════════════════════════════════════════════════════════

    function testFuzz_nonTreasurer_cannotSpend(address rando) public {
        vm.assume(rando != treasurerAddr);
        vm.assume(rando != address(0));

        // Make sure rando isn't another registered treasurer
        (bool isTres,) = treasurer.isTreasurer(rando);
        vm.assume(!isTres);

        vm.prank(rando);
        vm.expectRevert(TreasurerModule.NotTreasurer.selector);
        treasurer.treasurerSpendETH(outsider, 1 wei);
    }
}
