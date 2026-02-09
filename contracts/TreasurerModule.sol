// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
    TreasurerModule — Manages treasurer roles and direct fund spending.

    Two treasurer types:
      • MemberBased  – linked to a DAO member, spending scales with rank power.
      • AddressBased – linked to an EOA / contract, fixed spending limit.

    NFT transfer access can also be granted per-collection.

    State mutations come from:
      1.  Direct treasurer calls  (treasurerSpendETH, etc.)
      2.  Proposal execution forwarded by MembershipTreasury
          via `executeTreasurerAction()`.
*/

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IRankedMembershipDAO} from "./interfaces/IRankedMembershipDAO.sol";
import {IMembershipTreasury} from "./interfaces/IMembershipTreasury.sol";
import {ActionTypes} from "./libraries/ActionTypes.sol";

contract TreasurerModule is ReentrancyGuard {

    // ═══════════════════════════════ Constants ════════════════════════════════

    uint256 public constant MAX_SPENDING_LIMIT          = 10_000 ether;
    uint256 public constant MAX_SPENDING_LIMIT_PER_RANK = 1_000 ether;

    // ═══════════════════════════════ Immutables ══════════════════════════════

    IRankedMembershipDAO public immutable dao;

    // ═══════════════════════════════ Treasury link ════════════════════════════

    IMembershipTreasury public treasury;
    address private _deployer;

    // ═══════════════════════════════ Types ════════════════════════════════════

    enum TreasurerType { None, MemberBased, AddressBased }

    struct TreasurerConfig {
        bool   active;
        TreasurerType treasurerType;
        uint256 baseSpendingLimit;
        uint256 spendingLimitPerRankPower;
        uint64  periodDuration;
        IRankedMembershipDAO.Rank minRank;
    }

    struct TreasurerSpending {
        uint256 spentInPeriod;
        uint64  periodStart;
    }

    struct TokenSpendingConfig {
        bool    hasLimit;
        uint256 baseLimit;
        uint256 limitPerRankPower;
    }

    struct NFTAccessConfig {
        bool   hasAccess;
        uint64 transfersPerPeriod;
        uint64 periodDuration;
        IRankedMembershipDAO.Rank minRank;
    }

    struct NFTAccessTracking {
        uint64 transfersInPeriod;
        uint64 periodStart;
    }

    // ═══════════════════════════════ State ════════════════════════════════════

    // Member-based treasurers
    mapping(uint32 => TreasurerConfig)                    public memberTreasurers;
    mapping(uint32 => TreasurerSpending)                  public memberTreasurerSpending;
    mapping(uint32 => mapping(address => uint256))        public memberTreasurerTokenSpent;
    mapping(uint32 => mapping(address => TokenSpendingConfig)) public memberTreasurerTokenConfigs;

    // Address-based treasurers
    mapping(address => TreasurerConfig)                    public addressTreasurers;
    mapping(address => TreasurerSpending)                  public addressTreasurerSpending;
    mapping(address => mapping(address => uint256))        public addressTreasurerTokenSpent;
    mapping(address => mapping(address => TokenSpendingConfig)) public addressTreasurerTokenConfigs;

    // Member-based NFT access
    mapping(uint32 => mapping(address => NFTAccessConfig))   public memberNFTAccess;
    mapping(uint32 => mapping(address => NFTAccessTracking)) public memberNFTTracking;

    // Address-based NFT access
    mapping(address => mapping(address => NFTAccessConfig))   public addressNFTAccess;
    mapping(address => mapping(address => NFTAccessTracking)) public addressNFTTracking;

    // ═══════════════════════════════ Errors ═══════════════════════════════════

    error InvalidAddress();
    error ZeroAmount();
    error NotTreasurer();
    error NotTreasury();
    error TreasuryAlreadySet();
    error TreasurerSpendingLimitExceeded();
    error TreasurerNotActive();
    error TreasurerAlreadyExists();
    error InvalidPeriodDuration();
    error SpendingLimitTooHigh();
    error NoNFTAccess();
    error NFTTransferLimitExceeded();
    error NFTAccessAlreadyGranted();
    error NFTAccessNotGranted();
    error NotMember();
    error TreasuryLocked();
    error TreasurerCallsDisabled();
    error CallTargetNotApproved();
    error ExecutionFailed();
    error NFTNotOwned();
    error NotDeployer();

    // ═══════════════════════════════ Events ═══════════════════════════════════

    event TreasurySet(address indexed treasury);

    event TreasurerSpent(
        address indexed spender, TreasurerType treasurerType,
        address indexed recipient, address indexed token, uint256 amount
    );
    event TreasurerCallExecuted(
        address indexed spender, TreasurerType treasurerType,
        address indexed target, uint256 value, bytes data
    );
    event TreasurerNFTTransferred(
        address indexed spender, TreasurerType treasurerType,
        address indexed nftContract, address indexed to, uint256 tokenId
    );

    event MemberTreasurerAdded(uint32 indexed memberId, uint256 baseLim, uint256 limPerRank, uint64 period, IRankedMembershipDAO.Rank minRank);
    event MemberTreasurerUpdated(uint32 indexed memberId, uint256 baseLim, uint256 limPerRank, uint64 period, IRankedMembershipDAO.Rank minRank);
    event MemberTreasurerRemoved(uint32 indexed memberId);
    event MemberTreasurerTokenConfigSet(uint32 indexed memberId, address indexed token, uint256 baseLim, uint256 limPerRank);

    event AddressTreasurerAdded(address indexed treasurer, uint256 baseLim, uint64 period);
    event AddressTreasurerUpdated(address indexed treasurer, uint256 baseLim, uint64 period);
    event AddressTreasurerRemoved(address indexed treasurer);
    event AddressTreasurerTokenConfigSet(address indexed treasurer, address indexed token, uint256 limit);

    event NFTTransferred(address indexed nftContract, address indexed to, uint256 tokenId);
    event MemberNFTAccessGranted(uint32 indexed memberId, address indexed nftContract, uint64 txPerPeriod, uint64 period, IRankedMembershipDAO.Rank minRank);
    event MemberNFTAccessRevoked(uint32 indexed memberId, address indexed nftContract);
    event AddressNFTAccessGranted(address indexed treasurer, address indexed nftContract, uint64 txPerPeriod, uint64 period);
    event AddressNFTAccessRevoked(address indexed treasurer, address indexed nftContract);

    // ═══════════════════════════════ Modifiers ════════════════════════════════

    modifier onlyTreasury() {
        if (msg.sender != address(treasury)) revert NotTreasury();
        _;
    }

    // ═══════════════════════════════ Constructor ══════════════════════════════

    constructor(address _dao) {
        if (_dao == address(0)) revert InvalidAddress();
        dao = IRankedMembershipDAO(_dao);
        _deployer = msg.sender;
    }

    /// @notice Link this module to the Treasury.  Deployer-only, one-shot.
    function setTreasury(address _treasury) external {
        if (msg.sender != _deployer) revert NotDeployer();
        if (address(treasury) != address(0)) revert TreasuryAlreadySet();
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = IMembershipTreasury(_treasury);
        emit TreasurySet(_treasury);
    }

    // ═══════════════════════════════ Direct Spending ══════════════════════════

    function treasurerSpendETH(address to, uint256 amount) external nonReentrant {
        if (treasury.treasuryLocked()) revert TreasuryLocked();
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();

        (TreasurerType tType, uint256 limit, uint32 memberId) =
            _getTreasurerInfo(msg.sender, address(0));
        if (tType == TreasurerType.None) revert NotTreasurer();

        _checkAndRecordSpending(msg.sender, tType, memberId, address(0), amount, limit);
        treasury.moduleTransferETH(to, amount);

        emit TreasurerSpent(msg.sender, tType, to, address(0), amount);
    }

    function treasurerSpendERC20(address token, address to, uint256 amount) external nonReentrant {
        if (treasury.treasuryLocked()) revert TreasuryLocked();
        if (token == address(0) || to == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();

        (TreasurerType tType, uint256 limit, uint32 memberId) =
            _getTreasurerInfo(msg.sender, token);
        if (tType == TreasurerType.None) revert NotTreasurer();

        _checkAndRecordSpending(msg.sender, tType, memberId, token, amount, limit);
        treasury.moduleTransferERC20(token, to, amount);

        emit TreasurerSpent(msg.sender, tType, to, token, amount);
    }

    function treasurerTransferNFT(
        address nftContract, address to, uint256 tokenId
    ) external nonReentrant {
        if (treasury.treasuryLocked()) revert TreasuryLocked();
        if (nftContract == address(0) || to == address(0)) revert InvalidAddress();

        (TreasurerType tType, uint32 memberId, bool ok) =
            _checkNFTAccess(msg.sender, nftContract);
        if (!ok) revert NoNFTAccess();

        _checkAndRecordNFTTransfer(msg.sender, tType, memberId, nftContract);
        treasury.moduleTransferNFT(nftContract, to, tokenId);

        emit TreasurerNFTTransferred(msg.sender, tType, nftContract, to, tokenId);
    }

    function treasurerCall(
        address target, uint256 value, bytes calldata data
    ) external nonReentrant {
        if (treasury.treasuryLocked()) revert TreasuryLocked();
        if (target == address(0)) revert InvalidAddress();
        if (!treasury.treasurerCallsEnabled()) revert TreasurerCallsDisabled();
        if (!treasury.approvedCallTargets(target)) revert CallTargetNotApproved();

        (TreasurerType tType, uint256 limit, uint32 memberId) =
            _getTreasurerInfo(msg.sender, address(0));
        if (tType == TreasurerType.None) revert NotTreasurer();

        if (value > 0)
            _checkAndRecordSpending(msg.sender, tType, memberId, address(0), value, limit);

        treasury.moduleCall(target, value, data);

        emit TreasurerCallExecuted(msg.sender, tType, target, value, data);
    }

    // ═══════════════════════════════ Proposal Execution ═══════════════════════
    //  Called by MembershipTreasury.execute() for treasurer/NFT action types.

    function executeTreasurerAction(uint8 at, bytes calldata data) external onlyTreasury {
        if      (at == ActionTypes.ADD_MEMBER_TREASURER)     _execAddMemberTreasurer(data);
        else if (at == ActionTypes.UPDATE_MEMBER_TREASURER)  _execUpdateMemberTreasurer(data);
        else if (at == ActionTypes.REMOVE_MEMBER_TREASURER)  _execRemoveMemberTreasurer(data);
        else if (at == ActionTypes.ADD_ADDRESS_TREASURER)    _execAddAddressTreasurer(data);
        else if (at == ActionTypes.UPDATE_ADDRESS_TREASURER) _execUpdateAddressTreasurer(data);
        else if (at == ActionTypes.REMOVE_ADDRESS_TREASURER) _execRemoveAddressTreasurer(data);
        else if (at == ActionTypes.SET_MEMBER_TOKEN_CONFIG)  _execSetMemberTokenConfig(data);
        else if (at == ActionTypes.SET_ADDRESS_TOKEN_CONFIG) _execSetAddressTokenConfig(data);
        else if (at == ActionTypes.TRANSFER_NFT)             _execTransferNFT(data);
        else if (at == ActionTypes.GRANT_MEMBER_NFT_ACCESS)  _execGrantMemberNFTAccess(data);
        else if (at == ActionTypes.REVOKE_MEMBER_NFT_ACCESS) _execRevokeMemberNFTAccess(data);
        else if (at == ActionTypes.GRANT_ADDRESS_NFT_ACCESS) _execGrantAddressNFTAccess(data);
        else if (at == ActionTypes.REVOKE_ADDRESS_NFT_ACCESS) _execRevokeAddressNFTAccess(data);
        else revert ExecutionFailed();
    }

    // ─── Member Treasurer Execution ──────────────────────────────────────────

    function _execAddMemberTreasurer(bytes calldata data) internal {
        (uint32 mid, uint256 baseLim, uint256 limPerRank, uint64 period, uint8 minRank) =
            abi.decode(data, (uint32, uint256, uint256, uint64, uint8));

        (bool exists,,,,) = dao.membersById(mid);
        if (!exists)                            revert NotMember();
        if (memberTreasurers[mid].active)       revert TreasurerAlreadyExists();
        if (period == 0)                        revert InvalidPeriodDuration();
        if (baseLim > MAX_SPENDING_LIMIT)       revert SpendingLimitTooHigh();
        if (limPerRank > MAX_SPENDING_LIMIT_PER_RANK) revert SpendingLimitTooHigh();

        memberTreasurers[mid] = TreasurerConfig({
            active: true,
            treasurerType: TreasurerType.MemberBased,
            baseSpendingLimit: baseLim,
            spendingLimitPerRankPower: limPerRank,
            periodDuration: period,
            minRank: IRankedMembershipDAO.Rank(minRank)
        });
        emit MemberTreasurerAdded(mid, baseLim, limPerRank, period, IRankedMembershipDAO.Rank(minRank));
    }

    function _execUpdateMemberTreasurer(bytes calldata data) internal {
        (uint32 mid, uint256 baseLim, uint256 limPerRank, uint64 period, uint8 minRank) =
            abi.decode(data, (uint32, uint256, uint256, uint64, uint8));

        if (!memberTreasurers[mid].active) revert TreasurerNotActive();
        if (period == 0)                   revert InvalidPeriodDuration();
        if (baseLim > MAX_SPENDING_LIMIT)  revert SpendingLimitTooHigh();
        if (limPerRank > MAX_SPENDING_LIMIT_PER_RANK) revert SpendingLimitTooHigh();

        TreasurerConfig storage c = memberTreasurers[mid];
        c.baseSpendingLimit       = baseLim;
        c.spendingLimitPerRankPower = limPerRank;
        c.periodDuration          = period;
        c.minRank                 = IRankedMembershipDAO.Rank(minRank);
        emit MemberTreasurerUpdated(mid, baseLim, limPerRank, period, IRankedMembershipDAO.Rank(minRank));
    }

    function _execRemoveMemberTreasurer(bytes calldata data) internal {
        uint32 mid = abi.decode(data, (uint32));
        if (!memberTreasurers[mid].active) revert TreasurerNotActive();
        delete memberTreasurers[mid];
        delete memberTreasurerSpending[mid];
        emit MemberTreasurerRemoved(mid);
    }

    // ─── Address Treasurer Execution ─────────────────────────────────────────

    function _execAddAddressTreasurer(bytes calldata data) internal {
        (address addr, uint256 baseLim, uint64 period) =
            abi.decode(data, (address, uint256, uint64));

        if (addr == address(0))                 revert InvalidAddress();
        if (addressTreasurers[addr].active)     revert TreasurerAlreadyExists();
        if (period == 0)                        revert InvalidPeriodDuration();
        if (baseLim > MAX_SPENDING_LIMIT)       revert SpendingLimitTooHigh();

        addressTreasurers[addr] = TreasurerConfig({
            active: true,
            treasurerType: TreasurerType.AddressBased,
            baseSpendingLimit: baseLim,
            spendingLimitPerRankPower: 0,
            periodDuration: period,
            minRank: IRankedMembershipDAO.Rank.G
        });
        emit AddressTreasurerAdded(addr, baseLim, period);
    }

    function _execUpdateAddressTreasurer(bytes calldata data) internal {
        (address addr, uint256 baseLim, uint64 period) =
            abi.decode(data, (address, uint256, uint64));

        if (!addressTreasurers[addr].active) revert TreasurerNotActive();
        if (period == 0)                     revert InvalidPeriodDuration();
        if (baseLim > MAX_SPENDING_LIMIT)    revert SpendingLimitTooHigh();

        TreasurerConfig storage c = addressTreasurers[addr];
        c.baseSpendingLimit = baseLim;
        c.periodDuration    = period;
        emit AddressTreasurerUpdated(addr, baseLim, period);
    }

    function _execRemoveAddressTreasurer(bytes calldata data) internal {
        address addr = abi.decode(data, (address));
        if (!addressTreasurers[addr].active) revert TreasurerNotActive();
        delete addressTreasurers[addr];
        delete addressTreasurerSpending[addr];
        emit AddressTreasurerRemoved(addr);
    }

    // ─── Token Config Execution ──────────────────────────────────────────────

    function _execSetMemberTokenConfig(bytes calldata data) internal {
        (uint32 mid, address token, uint256 baseLim, uint256 limPerRank) =
            abi.decode(data, (uint32, address, uint256, uint256));
        if (!memberTreasurers[mid].active) revert TreasurerNotActive();
        memberTreasurerTokenConfigs[mid][token] = TokenSpendingConfig({
            hasLimit: true, baseLimit: baseLim, limitPerRankPower: limPerRank
        });
        emit MemberTreasurerTokenConfigSet(mid, token, baseLim, limPerRank);
    }

    function _execSetAddressTokenConfig(bytes calldata data) internal {
        (address addr, address token, uint256 limit) =
            abi.decode(data, (address, address, uint256));
        if (!addressTreasurers[addr].active) revert TreasurerNotActive();
        addressTreasurerTokenConfigs[addr][token] = TokenSpendingConfig({
            hasLimit: true, baseLimit: limit, limitPerRankPower: 0
        });
        emit AddressTreasurerTokenConfigSet(addr, token, limit);
    }

    // ─── NFT Execution ───────────────────────────────────────────────────────

    function _execTransferNFT(bytes calldata data) internal {
        if (treasury.treasuryLocked()) revert TreasuryLocked();
        (address nftContract, address to, uint256 tokenId) =
            abi.decode(data, (address, address, uint256));

        // Verify treasury owns the NFT
        try IERC721(nftContract).ownerOf(tokenId) returns (address nftOwner) {
            if (nftOwner != address(treasury)) revert NFTNotOwned();
        } catch { revert NFTNotOwned(); }

        treasury.moduleTransferNFT(nftContract, to, tokenId);
        emit NFTTransferred(nftContract, to, tokenId);
    }

    function _execGrantMemberNFTAccess(bytes calldata data) internal {
        (uint32 mid, address nftContract, uint64 txPer, uint64 period, uint8 minRank) =
            abi.decode(data, (uint32, address, uint64, uint64, uint8));

        (bool exists,,,,) = dao.membersById(mid);
        if (!exists) revert NotMember();
        if (memberNFTAccess[mid][nftContract].hasAccess) revert NFTAccessAlreadyGranted();

        memberNFTAccess[mid][nftContract] = NFTAccessConfig({
            hasAccess: true,
            transfersPerPeriod: txPer,
            periodDuration: period,
            minRank: IRankedMembershipDAO.Rank(minRank)
        });
        emit MemberNFTAccessGranted(mid, nftContract, txPer, period, IRankedMembershipDAO.Rank(minRank));
    }

    function _execRevokeMemberNFTAccess(bytes calldata data) internal {
        (uint32 mid, address nftContract) = abi.decode(data, (uint32, address));
        if (!memberNFTAccess[mid][nftContract].hasAccess) revert NFTAccessNotGranted();
        delete memberNFTAccess[mid][nftContract];
        delete memberNFTTracking[mid][nftContract];
        emit MemberNFTAccessRevoked(mid, nftContract);
    }

    function _execGrantAddressNFTAccess(bytes calldata data) internal {
        (address addr, address nftContract, uint64 txPer, uint64 period) =
            abi.decode(data, (address, address, uint64, uint64));

        if (addressNFTAccess[addr][nftContract].hasAccess) revert NFTAccessAlreadyGranted();
        addressNFTAccess[addr][nftContract] = NFTAccessConfig({
            hasAccess: true,
            transfersPerPeriod: txPer,
            periodDuration: period,
            minRank: IRankedMembershipDAO.Rank.G
        });
        emit AddressNFTAccessGranted(addr, nftContract, txPer, period);
    }

    function _execRevokeAddressNFTAccess(bytes calldata data) internal {
        (address addr, address nftContract) = abi.decode(data, (address, address));
        if (!addressNFTAccess[addr][nftContract].hasAccess) revert NFTAccessNotGranted();
        delete addressNFTAccess[addr][nftContract];
        delete addressNFTTracking[addr][nftContract];
        emit AddressNFTAccessRevoked(addr, nftContract);
    }

    // ═══════════════════════════════ Internal Helpers ═════════════════════════

    function _getTreasurerInfo(address spender, address token)
        internal view returns (TreasurerType tType, uint256 limit, uint32 memberId)
    {
        // ── Member-based ──
        memberId = dao.memberIdByAuthority(spender);
        if (memberId != 0 && memberTreasurers[memberId].active) {
            TreasurerConfig storage c = memberTreasurers[memberId];
            (bool exists,, IRankedMembershipDAO.Rank rank,,) = dao.membersById(memberId);
            if (!exists || uint8(rank) < uint8(c.minRank))
                return (TreasurerType.None, 0, 0);

            uint224 rp = dao.votingPowerOfRank(rank);
            if (token == address(0)) {
                limit = c.baseSpendingLimit + c.spendingLimitPerRankPower * rp;
            } else {
                TokenSpendingConfig storage tc = memberTreasurerTokenConfigs[memberId][token];
                limit = tc.hasLimit
                    ? tc.baseLimit + tc.limitPerRankPower * rp
                    : c.baseSpendingLimit + c.spendingLimitPerRankPower * rp;
            }
            return (TreasurerType.MemberBased, limit, memberId);
        }

        // ── Address-based ──
        if (addressTreasurers[spender].active) {
            TreasurerConfig storage c = addressTreasurers[spender];
            if (token == address(0)) {
                limit = c.baseSpendingLimit;
            } else {
                TokenSpendingConfig storage tc = addressTreasurerTokenConfigs[spender][token];
                limit = tc.hasLimit ? tc.baseLimit : c.baseSpendingLimit;
            }
            return (TreasurerType.AddressBased, limit, 0);
        }

        return (TreasurerType.None, 0, 0);
    }

    function _checkAndRecordSpending(
        address spender, TreasurerType tType, uint32 memberId,
        address token, uint256 amount, uint256 limit
    ) internal {
        uint64 ts = uint64(block.timestamp);

        if (tType == TreasurerType.MemberBased) {
            TreasurerConfig  storage c = memberTreasurers[memberId];
            TreasurerSpending storage s = memberTreasurerSpending[memberId];
            bool expired = ts >= s.periodStart + c.periodDuration;
            if (expired) { s.periodStart = ts; s.spentInPeriod = 0; }

            uint256 spent;
            if (token == address(0)) {
                spent = expired ? 0 : s.spentInPeriod;
                if (spent + amount > limit) revert TreasurerSpendingLimitExceeded();
                s.spentInPeriod = spent + amount;
            } else {
                spent = expired ? 0 : memberTreasurerTokenSpent[memberId][token];
                if (spent + amount > limit) revert TreasurerSpendingLimitExceeded();
                memberTreasurerTokenSpent[memberId][token] = spent + amount;
            }
        } else {
            TreasurerConfig  storage c = addressTreasurers[spender];
            TreasurerSpending storage s = addressTreasurerSpending[spender];
            bool expired = ts >= s.periodStart + c.periodDuration;
            if (expired) { s.periodStart = ts; s.spentInPeriod = 0; }

            uint256 spent;
            if (token == address(0)) {
                spent = expired ? 0 : s.spentInPeriod;
                if (spent + amount > limit) revert TreasurerSpendingLimitExceeded();
                s.spentInPeriod = spent + amount;
            } else {
                spent = expired ? 0 : addressTreasurerTokenSpent[spender][token];
                if (spent + amount > limit) revert TreasurerSpendingLimitExceeded();
                addressTreasurerTokenSpent[spender][token] = spent + amount;
            }
        }
    }

    function _checkNFTAccess(address spender, address nftContract)
        internal view returns (TreasurerType tType, uint32 memberId, bool canTransfer)
    {
        memberId = dao.memberIdByAuthority(spender);
        if (memberId != 0) {
            NFTAccessConfig storage c = memberNFTAccess[memberId][nftContract];
            if (c.hasAccess) {
                (bool exists,, IRankedMembershipDAO.Rank rank,,) = dao.membersById(memberId);
                if (exists && uint8(rank) >= uint8(c.minRank))
                    return (TreasurerType.MemberBased, memberId, true);
            }
        }
        if (addressNFTAccess[spender][nftContract].hasAccess)
            return (TreasurerType.AddressBased, 0, true);

        return (TreasurerType.None, 0, false);
    }

    function _checkAndRecordNFTTransfer(
        address spender, TreasurerType tType, uint32 memberId, address nftContract
    ) internal {
        uint64 ts = uint64(block.timestamp);

        NFTAccessConfig   storage c;
        NFTAccessTracking storage t;
        if (tType == TreasurerType.MemberBased) {
            c = memberNFTAccess[memberId][nftContract];
            t = memberNFTTracking[memberId][nftContract];
        } else {
            c = addressNFTAccess[spender][nftContract];
            t = addressNFTTracking[spender][nftContract];
        }

        if (c.periodDuration > 0 && ts >= t.periodStart + c.periodDuration) {
            t.periodStart       = ts;
            t.transfersInPeriod = 0;
        }
        if (c.transfersPerPeriod > 0) {
            if (t.transfersInPeriod >= c.transfersPerPeriod) revert NFTTransferLimitExceeded();
            t.transfersInPeriod++;
        }
    }

    // ═══════════════════════════════ Views ════════════════════════════════════

    function getMemberTreasurerConfig(uint32 memberId)
        external view returns (TreasurerConfig memory)
    {
        return memberTreasurers[memberId];
    }

    function getAddressTreasurerConfig(address treasurer)
        external view returns (TreasurerConfig memory)
    {
        return addressTreasurers[treasurer];
    }

    function isTreasurer(address spender) external view returns (bool, TreasurerType) {
        (TreasurerType tType,,) = _getTreasurerInfo(spender, address(0));
        return (tType != TreasurerType.None, tType);
    }

    function getTreasurerRemainingLimit(address spender) external view returns (uint256) {
        (TreasurerType tType, uint256 limit, uint32 memberId) =
            _getTreasurerInfo(spender, address(0));
        if (tType == TreasurerType.None) return 0;

        uint64 ts = uint64(block.timestamp);
        if (tType == TreasurerType.MemberBased) {
            TreasurerSpending storage s = memberTreasurerSpending[memberId];
            if (ts >= s.periodStart + memberTreasurers[memberId].periodDuration) return limit;
            return limit > s.spentInPeriod ? limit - s.spentInPeriod : 0;
        } else {
            TreasurerSpending storage s = addressTreasurerSpending[spender];
            if (ts >= s.periodStart + addressTreasurers[spender].periodDuration) return limit;
            return limit > s.spentInPeriod ? limit - s.spentInPeriod : 0;
        }
    }

    function getMemberNFTAccess(uint32 memberId, address nftContract)
        external view returns (NFTAccessConfig memory)
    {
        return memberNFTAccess[memberId][nftContract];
    }

    function getAddressNFTAccess(address treasurer, address nftContract)
        external view returns (NFTAccessConfig memory)
    {
        return addressNFTAccess[treasurer][nftContract];
    }

    function hasNFTAccessView(address spender, address nftContract)
        external view returns (bool canTransfer, TreasurerType tType)
    {
        (tType,, canTransfer) = _checkNFTAccess(spender, nftContract);
    }
}
