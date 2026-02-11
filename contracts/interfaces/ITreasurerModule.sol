// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITreasurerModule — Interface for the TreasurerModule contract
///        that executes treasurer actions on behalf of the treasury.
interface ITreasurerModule {
    function executeTreasurerAction(uint8 actionType, bytes calldata data) external;
}
