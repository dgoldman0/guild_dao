// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Interface for RankedMembershipDAO
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

    function votingPowerOfRank(Rank r) external pure returns (uint224);

    // Governance parameters (configurable via DAO governance)
    function votingPeriod() external view returns (uint64);
    function quorumBps() external view returns (uint16);
    function executionDelay() external view returns (uint64);
}
