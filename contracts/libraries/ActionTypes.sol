// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ActionTypes — Shared action-type constants for Treasury proposals.
/// @author Guild DAO
/// @notice Defines numeric constants for each treasury proposal action type.
///         Actions 0–2 and 16–20 are executed by MembershipTreasury directly;
///         actions 3–15 are forwarded to TreasurerModule.
library ActionTypes {
    // ── Basic (executed by MembershipTreasury) ──
    uint8 constant TRANSFER_ETH             = 0;
    uint8 constant TRANSFER_ERC20           = 1;
    uint8 constant CALL                     = 2;

    // ── Treasurer management (forwarded to TreasurerModule) ──
    uint8 constant ADD_MEMBER_TREASURER     = 3;
    uint8 constant UPDATE_MEMBER_TREASURER  = 4;
    uint8 constant REMOVE_MEMBER_TREASURER  = 5;
    uint8 constant ADD_ADDRESS_TREASURER    = 6;
    uint8 constant UPDATE_ADDRESS_TREASURER = 7;
    uint8 constant REMOVE_ADDRESS_TREASURER = 8;
    uint8 constant SET_MEMBER_TOKEN_CONFIG  = 9;
    uint8 constant SET_ADDRESS_TOKEN_CONFIG = 10;

    // ── NFT actions (forwarded to TreasurerModule) ──
    uint8 constant TRANSFER_NFT             = 11;
    uint8 constant GRANT_MEMBER_NFT_ACCESS  = 12;
    uint8 constant REVOKE_MEMBER_NFT_ACCESS = 13;
    uint8 constant GRANT_ADDRESS_NFT_ACCESS = 14;
    uint8 constant REVOKE_ADDRESS_NFT_ACCESS = 15;

    // ── Settings (executed by MembershipTreasury) ──
    uint8 constant SET_CALL_ACTIONS_ENABLED    = 16;
    uint8 constant SET_TREASURER_CALLS_ENABLED = 17;
    uint8 constant ADD_APPROVED_CALL_TARGET    = 18;
    uint8 constant REMOVE_APPROVED_CALL_TARGET = 19;
    uint8 constant SET_TREASURY_LOCKED         = 20;

    uint8 constant MAX_ACTION_TYPE = 20;

    /// @notice True when the action should be forwarded to TreasurerModule.
    function isModuleAction(uint8 at) internal pure returns (bool) {
        return at >= ADD_MEMBER_TREASURER && at <= REVOKE_ADDRESS_NFT_ACCESS;
    }
}
