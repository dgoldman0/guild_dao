// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {RankedMembershipDAO} from "../../contracts/RankedMembershipDAO.sol";
import {GuildController}     from "../../contracts/GuildController.sol";
import {OrderController}     from "../../contracts/OrderController.sol";
import {ProposalController}  from "../../contracts/ProposalController.sol";
import {InviteController}    from "../../contracts/InviteController.sol";
import {MembershipTreasury}  from "../../contracts/MembershipTreasury.sol";
import {TreasurerModule}     from "../../contracts/TreasurerModule.sol";
import {FeeRouter}           from "../../contracts/FeeRouter.sol";
import {MockERC20}           from "../../contracts/mocks/MockERC20.sol";
import {MockERC721}          from "../../contracts/mocks/MockERC721.sol";

/// @title GuildDeployHelper — Deploys the full 8-contract system for fuzz tests.
/// @dev   All contracts wired, bootstrap finalized, ready for testing.
abstract contract GuildDeployHelper is Test {
    RankedMembershipDAO public dao;
    GuildController     public guild;
    OrderController     public orders;
    ProposalController  public proposals;
    InviteController    public invites;
    MembershipTreasury  public treasury;
    TreasurerModule     public treasurer;
    FeeRouter           public feeRouter;
    MockERC20           public token;
    MockERC721          public nft;

    // Default accounts
    address public owner;        // deployer (SSS bootstrap member)
    address public memberF;      // rank F member
    address public memberE;      // rank E member
    address public memberD;      // rank D member
    address public outsider;     // non-member

    uint32 public ownerMemberId;
    uint32 public memberFId;
    uint32 public memberEId;
    uint32 public memberDId;

    function _deploySystem() internal {
        owner    = address(this);
        memberF  = address(0xF001);
        memberE  = address(0xE001);
        memberD  = address(0xD001);
        outsider = address(0xBAD);

        // ────────── Deploy core ──────────
        dao = new RankedMembershipDAO();   // deployer = SSS member (id=1)
        ownerMemberId = 1;

        // Bootstrap more members
        dao.bootstrapAddMember(memberF, RankedMembershipDAO.Rank.F);
        memberFId = 2;
        dao.bootstrapAddMember(memberE, RankedMembershipDAO.Rank.E);
        memberEId = 3;
        dao.bootstrapAddMember(memberD, RankedMembershipDAO.Rank.D);
        memberDId = 4;

        // ────────── Deploy controllers ──────────
        guild     = new GuildController(address(dao));
        orders    = new OrderController(address(dao), address(guild));
        proposals = new ProposalController(address(dao), address(orders), address(guild));
        invites   = new InviteController(address(dao), address(guild));

        // Wire GuildController
        guild.setOrderController(address(orders));
        guild.setProposalController(address(proposals));
        guild.setInviteController(address(invites));
        orders.setProposalController(address(proposals));

        // Set controller on DAO
        dao.setController(address(guild));

        // ────────── Deploy treasury ──────────
        treasury  = new MembershipTreasury(address(dao));
        treasurer = new TreasurerModule(address(dao));
        treasurer.setTreasury(address(treasury));
        treasury.setTreasurerModule(address(treasurer));

        // ────────── Deploy fee system ──────────
        feeRouter = new FeeRouter(address(dao));
        dao.setFeeRouter(address(feeRouter));

        // ────────── Deploy mocks ──────────
        token = new MockERC20("MockToken", "MTK");
        nft   = new MockERC721("MockNFT", "MNFT");

        // ────────── Finalize ──────────
        dao.finalizeBootstrap();
    }

    /// @dev Helper to fund the treasury with ETH
    function _fundTreasuryETH(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(treasury).call{value: amount}("");
        require(ok, "ETH funding failed");
    }

    /// @dev Helper to fund the treasury with ERC-20
    function _fundTreasuryToken(uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(treasury), amount);
        treasury.depositERC20(address(token), amount);
    }

    /// @dev Helper: run a treasury proposal through the full lifecycle
    function _passAndExecuteProposal(uint8 actionType, bytes memory data) internal {
        // Owner (SSS rank) proposes
        uint64 pid = treasury.propose(actionType, data);

        // Vote with max weight
        vm.roll(block.number + 2);     // advance past snapshot + VOTING_DELAY
        treasury.castVote(pid, true);

        // Advance past voting period and finalize
        vm.warp(block.timestamp + dao.votingPeriod() + 1);
        treasury.finalize(pid);

        // Advance past execution delay and execute
        vm.warp(block.timestamp + dao.executionDelay() + 1);
        treasury.execute(pid);
    }

    receive() external payable {}
}
