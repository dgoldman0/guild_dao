// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRankedMembershipDAO — Interface for external contracts to read DAO state.
/// @notice Used by MembershipTreasury, TreasurerModule, and FeeRouter.
interface IRankedMembershipDAO {
    enum Rank { G, F, E, D, C, B, A, S, SS, SSS }

    function memberIdByAuthority(address a) external view returns (uint32);

    function membersById(uint32 id)
        external
        view
        returns (
            bool exists,
            uint32 memberId,
            Rank rank,
            address authority,
            uint64 joinedAt
        );

    function votingPowerOfMemberAt(uint32 memberId, uint32 blockNumber) external view returns (uint224);
    function totalVotingPowerAt(uint32 blockNumber) external view returns (uint224);

    function proposalLimitOfRank(Rank r) external pure returns (uint8);

    function orderLimitOfRank(Rank r) external pure returns (uint8);

    function votingPowerOfRank(Rank r) external pure returns (uint224);

    // Governance parameters (configurable via DAO governance)
    function votingPeriod() external view returns (uint64);
    function quorumBps() external view returns (uint16);
    function executionDelay() external view returns (uint64);

    // Fee system
    function EPOCH() external view returns (uint64);
    function feeToken() external view returns (address);
    function baseFee() external view returns (uint256);
    function feeOfRank(Rank r) external view returns (uint256);
    function feePaidUntil(uint32 memberId) external view returns (uint64);
    function isMemberActive(uint32 memberId) external view returns (bool);
    function payoutTreasury() external view returns (address);
    function recordFeePayment(uint32 memberId) external;
}
