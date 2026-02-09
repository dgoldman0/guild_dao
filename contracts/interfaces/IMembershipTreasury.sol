// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IMembershipTreasury — Interface used by TreasurerModule to interact
///        with the MembershipTreasury that holds all funds.
interface IMembershipTreasury {
    // ── Settings reads ──
    function treasuryLocked() external view returns (bool);
    function treasurerCallsEnabled() external view returns (bool);
    function approvedCallTargets(address target) external view returns (bool);

    // ── Module-restricted fund movements ──
    function moduleTransferETH(address to, uint256 amount) external;
    function moduleTransferERC20(address token, address to, uint256 amount) external;
    function moduleTransferNFT(address nftContract, address to, uint256 tokenId) external;
    function moduleCall(address target, uint256 value, bytes calldata data)
        external returns (bytes memory);
}
