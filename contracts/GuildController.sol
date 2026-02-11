// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    GuildController — The sole controller of RankedMembershipDAO.

    Acts as an authorization gateway: holds references to the three
    sub-controllers and forwards their calls to the DAO after verifying
    the caller is authorized.

      OrderController    ──┐
      ProposalController ──┼──► GuildController ──► RankedMembershipDAO
      InviteController   ──┘

    setRank / setAuthority   → OrderController or ProposalController
    governance param setters → ProposalController only
    transferERC20, etc.      → ProposalController only
    addMember                → InviteController only
*/

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

    function setOrderController(address _oc) external {
        if (msg.sender != dao.owner() && msg.sender != proposalController)
            revert NotAuthorized();
        if (_oc == address(0)) revert InvalidAddress();
        orderController = _oc;
        emit OrderControllerSet(_oc);
    }

    function setProposalController(address _pc) external {
        if (msg.sender != dao.owner() && msg.sender != proposalController)
            revert NotAuthorized();
        if (_pc == address(0)) revert InvalidAddress();
        proposalController = _pc;
        emit ProposalControllerSet(_pc);
    }

    function setInviteController(address _ic) external {
        if (msg.sender != dao.owner() && msg.sender != proposalController)
            revert NotAuthorized();
        if (_ic == address(0)) revert InvalidAddress();
        inviteController = _ic;
        emit InviteControllerSet(_ic);
    }

    // ── Forwarding: rank / authority (either sub-controller) ──

    function setRank(
        uint32 memberId,
        RankedMembershipDAO.Rank newRank,
        uint32 byMemberId,
        bool viaGovernance
    ) external onlySubController {
        dao.setRank(memberId, newRank, byMemberId, viaGovernance);
    }

    function setAuthority(
        uint32 memberId,
        address newAuthority,
        uint32 byMemberId,
        bool viaGovernance
    ) external onlySubController {
        dao.setAuthority(memberId, newAuthority, byMemberId, viaGovernance);
    }

    // ── Forwarding: governance params (ProposalController only) ──

    function setVotingPeriod(uint64 newValue) external onlyProposalController {
        dao.setVotingPeriod(newValue);
    }

    function setQuorumBps(uint16 newValue) external onlyProposalController {
        dao.setQuorumBps(newValue);
    }

    function setOrderDelay(uint64 newValue) external onlyProposalController {
        dao.setOrderDelay(newValue);
    }

    function setInviteExpiry(uint64 newValue) external onlyProposalController {
        dao.setInviteExpiry(newValue);
    }

    function setExecutionDelay(uint64 newValue) external onlyProposalController {
        dao.setExecutionDelay(newValue);
    }

    // ── Forwarding: special actions (ProposalController only) ──

    function transferERC20(address token, address recipient, uint256 amount)
        external onlyProposalController
    {
        dao.transferERC20(token, recipient, amount);
    }

    function resetBootstrapFee(uint32 memberId) external onlyProposalController {
        dao.resetBootstrapFee(memberId);
    }

    function setMemberActive(uint32 memberId, bool _active)
        external onlyProposalController
    {
        dao.setMemberActive(memberId, _active);
    }

    // ── Forwarding: invite (InviteController only) ──────────

    function addMember(address authority)
        external onlyInviteController returns (uint32)
    {
        return dao.addMember(authority);
    }
}
