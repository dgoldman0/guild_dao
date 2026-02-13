// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FeeRouter — Dedicated membership-fee collection contract.
/// @author Guild DAO
/// @notice Reads fee configuration from the DAO, collects ETH or ERC-20,
///         forwards funds to the payout treasury, and calls
///         `dao.recordFeePayment()` to extend the member's paid-until epoch.
/// @dev    The DAO holds fee configuration (feeToken, baseFee, gracePeriod,
///         payoutTreasury) and member active/inactive state.  This contract is
///         the single authorized caller of `dao.recordFeePayment()`.

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRankedMembershipDAO} from "./interfaces/IRankedMembershipDAO.sol";

contract FeeRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ════════════════════════════ Immutables ═════════════════════════════════

    IRankedMembershipDAO public immutable dao;

    // ════════════════════════════ Errors ═════════════════════════════════════

    error InvalidAddress();
    error NotMember();
    error FeeNotConfigured();
    error PayoutTreasuryNotSet();
    error IncorrectFeeAmount();
    error TransferFailed();

    // ════════════════════════════ Events ═════════════════════════════════════

    event MembershipFeePaid(
        uint32 indexed memberId,
        address indexed payer,
        address feeToken,
        uint256 amount,
        address payoutTreasury
    );

    // ════════════════════════════ Constructor ════════════════════════════════

    constructor(address _dao) {
        if (_dao == address(0)) revert InvalidAddress();
        dao = IRankedMembershipDAO(_dao);
    }

    // ════════════════════════════ Pay Fee ════════════════════════════════════

    /// @notice Pay the membership fee for `memberId`.
    /// @dev    If the DAO's feeToken is address(0), send ETH (msg.value must
    ///         equal the fee).  Otherwise, approve this contract for the ERC-20
    ///         amount before calling.  Anyone can pay on behalf of any member.
    /// @param memberId The DAO member ID to pay for.
    function payMembershipFee(uint32 memberId) external payable nonReentrant {
        // --- resolve member rank ---
        (bool exists,, IRankedMembershipDAO.Rank rank,,) = dao.membersById(memberId);
        if (!exists) revert NotMember();

        // --- resolve fee amount ---
        uint256 fee = dao.feeOfRank(rank);
        if (fee == 0) revert FeeNotConfigured();

        // --- resolve payout destination ---
        address payout = dao.payoutTreasury();
        if (payout == address(0)) revert PayoutTreasuryNotSet();

        // --- resolve fee token ---
        address token = dao.feeToken();

        if (token == address(0)) {
            // ── ETH path ──
            if (msg.value != fee) revert IncorrectFeeAmount();
            (bool ok,) = payout.call{value: fee}("");
            if (!ok) revert TransferFailed();
        } else {
            // ── ERC-20 path ──
            if (msg.value != 0) revert IncorrectFeeAmount();
            IERC20(token).safeTransferFrom(msg.sender, payout, fee);
        }

        // --- tell the DAO to extend the member's paid-until ---
        dao.recordFeePayment(memberId);

        emit MembershipFeePaid(memberId, msg.sender, token, fee, payout);
    }
}
