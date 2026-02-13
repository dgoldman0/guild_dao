// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GuildController — Authorization gateway between sub-controllers and the DAO.
/// @author Guild DAO
/// @notice Acts as the sole `controller` of RankedMembershipDAO.  Holds references
///         to OrderController, ProposalController, and InviteController, and
///         forwards their calls to the DAO after verifying the caller is authorized.
/// @dev    OrderController and ProposalController may both call setRank / setAuthority.
///         Only ProposalController may call governance parameter setters and special
///         actions.  Only InviteController may call addMember.

import {RankedMembershipDAO} from "./RankedMembershipDAO.sol";

contract GuildController {

    RankedMembershipDAO public immutable dao;

    address public orderController;
    address public proposalController;
    address public inviteController;

    // ── Errors ─────────────────────────────────
    error NotAuthorized();
    error InvalidAddress();

    // ── Events ─────────────────────────────────
    event OrderControllerSet(address indexed orderController);
    event ProposalControllerSet(address indexed proposalController);
    event InviteControllerSet(address indexed inviteController);

    // ── Constructor ────────────────────────────
    constructor(address daoAddress) {
        if (daoAddress == address(0)) revert InvalidAddress();
        dao = RankedMembershipDAO(payable(daoAddress));
    }

    // ── Auth modifiers ─────────────────────────

    modifier onlySubController() {
        if (msg.sender != orderController && msg.sender != proposalController)
            revert NotAuthorized();
        _;
    }

    modifier onlyProposalController() {
        if (msg.sender != proposalController) revert NotAuthorized();
        _;
    }

    modifier onlyInviteController() {
        if (msg.sender != inviteController) revert NotAuthorized();
        _;
    }

    // ── Sub-controller setup ───────────────────
    //    DAO owner during bootstrap, proposalController after.

    /// @notice Set the OrderController address.
    /// @dev Callable by DAO owner (bootstrap) or proposalController (governance).
    /// @param newOrderController The new OrderController address (non-zero).
    function setOrderController(address newOrderController) external {
        if (msg.sender != dao.owner() && msg.sender != proposalController)
            revert NotAuthorized();
        if (newOrderController == address(0)) revert InvalidAddress();
        orderController = newOrderController;
        emit OrderControllerSet(newOrderController);
    }

    /// @notice Set the ProposalController address.
    /// @dev Callable by DAO owner (bootstrap) or proposalController (governance).
    /// @param newProposalController The new ProposalController address (non-zero).
    function setProposalController(address newProposalController) external {
        if (msg.sender != dao.owner() && msg.sender != proposalController)
            revert NotAuthorized();
        if (newProposalController == address(0)) revert InvalidAddress();
        proposalController = newProposalController;
        emit ProposalControllerSet(newProposalController);
    }

    /// @notice Set the InviteController address.
    /// @dev Callable by DAO owner (bootstrap) or proposalController (governance).
    /// @param newInviteController The new InviteController address (non-zero).
    function setInviteController(address newInviteController) external {
        if (msg.sender != dao.owner() && msg.sender != proposalController)
            revert NotAuthorized();
        if (newInviteController == address(0)) revert InvalidAddress();
        inviteController = newInviteController;
        emit InviteControllerSet(newInviteController);
    }

    // ── Forwarding: rank / authority (either sub-controller) ──

    /// @notice Forward a setRank call to the DAO.
    /// @dev Callable by OrderController or ProposalController.
    function setRank(
        uint32 memberId,
        RankedMembershipDAO.Rank newRank,
        uint32 byMemberId,
        bool viaGovernance
    ) external onlySubController {
        dao.setRank(memberId, newRank, byMemberId, viaGovernance);
    }

    /// @notice Forward a setAuthority call to the DAO.
    /// @dev Callable by OrderController or ProposalController.
    function setAuthority(
        uint32 memberId,
        address newAuthority,
        uint32 byMemberId,
        bool viaGovernance
    ) external onlySubController {
        dao.setAuthority(memberId, newAuthority, byMemberId, viaGovernance);
    }

    // ── Forwarding: governance params (ProposalController only) ──

    /// @notice Forward setVotingPeriod to DAO. ProposalController only.
    function setVotingPeriod(uint64 newValue) external onlyProposalController {
        dao.setVotingPeriod(newValue);
    }

    /// @notice Forward setQuorumBps to DAO. ProposalController only.
    function setQuorumBps(uint16 newValue) external onlyProposalController {
        dao.setQuorumBps(newValue);
    }

    /// @notice Forward setOrderDelay to DAO. ProposalController only.
    function setOrderDelay(uint64 newValue) external onlyProposalController {
        dao.setOrderDelay(newValue);
    }

    /// @notice Forward setInviteExpiry to DAO. ProposalController only.
    function setInviteExpiry(uint64 newValue) external onlyProposalController {
        dao.setInviteExpiry(newValue);
    }

    /// @notice Forward setExecutionDelay to DAO. ProposalController only.
    function setExecutionDelay(uint64 newValue) external onlyProposalController {
        dao.setExecutionDelay(newValue);
    }

    // ── Forwarding: special actions (ProposalController only) ──

    /// @notice Forward transferERC20 to DAO. ProposalController only.
    function transferERC20(address token, address recipient, uint256 amount)
        external onlyProposalController
    {
        dao.transferERC20(token, recipient, amount);
    }

    /// @notice Forward resetBootstrapFee to DAO. ProposalController only.
    function resetBootstrapFee(uint32 memberId) external onlyProposalController {
        dao.resetBootstrapFee(memberId);
    }

    /// @notice Forward setMemberActive to DAO. ProposalController only.
    function setMemberActive(uint32 memberId, bool active)
        external onlyProposalController
    {
        dao.setMemberActive(memberId, active);
    }

    // ── Forwarding: invite (InviteController only) ──────────

    /// @notice Create a new G-rank member via the DAO. InviteController only.
    /// @param authority The wallet address of the new member.
    /// @return The new member's ID.
    function addMember(address authority)
        external onlyInviteController returns (uint32)
    {
        return dao.addMember(authority);
    }
}
