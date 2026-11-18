// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

interface ICuratorRegistry {
    function isApproved(address curator) external view returns (bool);
}

/// @title CuratorVaultHook
/// @notice Uniswap v4 hook that enforces curator mandates at the pool level:
/// only the CuratorVault may manage liquidity, range width and rebalance frequency are
/// bounded on-chain, and a dynamic LP fee rises when price moves away from an EMA refPrice.
/// The verified-curator score is written by a Brevis-style callback and gates who may act.
contract CuratorVaultHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    error OnlyPoolManager();
    error OnlyVault();
    error UnverifiedCurator();
    error RangeTooWide();
    error RebalanceTooSoon();
    error UnauthorizedVerifier();
    error Unauthorized();
    error SamePool();
    error FeeNotAuthorized();
    error FeeTooHigh();

    IPoolManager public immutable poolManager;
    address public owner;

    address public vault;
    address public strategy;
    address public verifier;
    address public registry;

    uint24 public baseFee;
    uint24 public maxFee;
    uint24 public feeSlope;
    int24 public maxRangeWidth;
    uint256 public minRebalanceInterval;

    uint256 public lastRebalance;
    uint256 public totalLiquidityEvents;

    uint160 public emaSqrtPriceX96;
    uint256 public lastEmaTimestamp;
    uint256 public emaWindow;

    mapping(address => uint256) public verifiedScore;
    mapping(PoolId => bool) public supportedPool;
    mapping(PoolId => uint160) public poolEmaPrice;

    mapping(PoolId => uint256) public poolHighWaterMark;
    uint256 public maxPerformanceFeeBps;

    event VaultSet(address vault);
    event StrategySet(address strategy);
    event VerifierSet(address verifier);
    event PoolSupported(PoolId indexed id);
    event VerificationUpdated(address indexed curator, uint256 score);
    event RebalanceExecuted(PoolId indexed id, address indexed curator, int24 tickLower, int24 tickUpper);
    event DynamicFeeSet(PoolId indexed id, uint24 fee);
    event RegistrySet(address registry);
    event FeeAuthorized(PoolId indexed id, uint256 sharePrice, uint256 benchmark, uint256 allowedBps);

    constructor(
        address _owner,
        IPoolManager _poolManager,
        uint24 _baseFee,
        uint24 _maxFee,
        uint24 _feeSlope,
        int24 _maxRangeWidth,
        uint256 _minRebalanceInterval,
        uint256 _emaWindow
    ) {
        owner = _owner;
        poolManager = _poolManager;
        baseFee = _baseFee;
        maxFee = _maxFee;
        feeSlope = _feeSlope;
        maxRangeWidth = _maxRangeWidth;
        minRebalanceInterval = _minRebalanceInterval;
        emaWindow = _emaWindow;

        Hooks.validateHookPermissions(
            this,
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function setVault(address _vault) external onlyOwner {
        if (vault != address(0)) revert UnauthorizedVerifier();
        vault = _vault;
        emit VaultSet(_vault);
    }

    function setStrategy(address _strategy) external onlyOwner {
        if (strategy != address(0)) revert UnauthorizedVerifier();
        strategy = _strategy;
        emit StrategySet(_strategy);
    }

    function setVerifier(address _verifier) external onlyOwner {
        if (verifier != address(0)) revert UnauthorizedVerifier();
        verifier = _verifier;
        emit VerifierSet(_verifier);
    }

    function setRegistry(address _registry) external onlyOwner {
        if (registry != address(0)) revert UnauthorizedVerifier();
        registry = _registry;
        emit RegistrySet(_registry);
    }

    function setMaxPerformanceFeeBps(uint256 _bps) external onlyOwner {
        if (_bps > 5000) revert FeeTooHigh();
        maxPerformanceFeeBps = _bps;
    }

    function setSupportedPool(PoolKey calldata key) external {
        if (msg.sender != vault) revert OnlyVault();
        PoolId id = key.toId();
        supportedPool[id] = true;
        (uint160 price,,,) = StateLibrary.getSlot0(poolManager, id);
        poolEmaPrice[id] = price;
        emaSqrtPriceX96 = price;
        lastEmaTimestamp = block.timestamp;
        emit PoolSupported(id);
    }

    function submitVerification(address curator, uint256 score, bytes calldata) external {
        if (msg.sender != verifier) revert UnauthorizedVerifier();
        verifiedScore[curator] = score;
        emit VerificationUpdated(curator, score);
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external override onlyManager returns (bytes4) {
        if (sender != vault) revert OnlyVault();
        PoolId id = key.toId();
        if (!supportedPool[id]) revert SamePool();
        if (params.tickUpper - params.tickLower > maxRangeWidth) revert RangeTooWide();
        if (lastRebalance != 0 && block.timestamp < lastRebalance + minRebalanceInterval) revert RebalanceTooSoon();
        if (!_curatorApproved(strategy)) revert UnverifiedCurator();
        lastRebalance = block.timestamp;
        totalLiquidityEvents++;
        emit RebalanceExecuted(id, strategy, params.tickLower, params.tickUpper);
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyManager returns (bytes4) {
        if (sender != vault) revert OnlyVault();
        if (!supportedPool[key.toId()]) revert SamePool();
        totalLiquidityEvents++;
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (uint160 current,,,) = StateLibrary.getSlot0(poolManager, id);
        uint160 refPrice = poolEmaPrice[id];
        if (refPrice == 0) refPrice = current;

        uint24 fee = computeFee(current, refPrice);
        emit DynamicFeeSet(id, fee);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        onlyManager
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        (uint160 current,,,) = StateLibrary.getSlot0(poolManager, id);
        uint160 refPrice = poolEmaPrice[id];
        if (refPrice == 0) {
            poolEmaPrice[id] = current;
        } else {
            poolEmaPrice[id] = uint160((uint256(refPrice) * (emaWindow - 1) + uint256(current)) / emaWindow);
        }
        emaSqrtPriceX96 = poolEmaPrice[id];
        lastEmaTimestamp = block.timestamp;
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    function computeFee(uint160 current, uint160 refPrice) public view returns (uint24) {
        uint256 diff = current > refPrice ? uint256(current) - refPrice : uint256(refPrice) - current;
        uint256 deviationBps = (diff * 10_000) / uint256(refPrice);
        uint256 additional = (deviationBps * uint256(feeSlope)) / 100;
        uint256 fee = uint256(baseFee) + additional;
        if (fee > uint256(maxFee)) fee = uint256(maxFee);
        return uint24(fee);
    }

    /// @notice EMA price used for NAV and fee valuation, in Q64.96 sqrt-price squared terms.
    function getEmaPriceX192(PoolId id) public view returns (uint256) {
        uint160 ema = poolEmaPrice[id];
        if (ema == 0) {
            (ema,,,) = StateLibrary.getSlot0(poolManager, id);
        }
        return uint256(ema) * uint256(ema);
    }

    /// @notice Hook decides whether a performance fee may be taken. The vault calls this before
    /// charging depositors; the hook compares share price against its own high-water mark and the
    /// HODL benchmark. Fee is zero unless both are beaten.
    function authorizeFee(PoolId id, uint256 sharePrice, uint256 benchmark, uint256 requestedBps)
        external
        returns (uint256 allowedBps)
    {
        if (msg.sender != vault) revert OnlyVault();
        uint256 mark = poolHighWaterMark[id];
        if (mark == 0) mark = 1e18;
        if (sharePrice <= mark || sharePrice <= benchmark) {
            emit FeeAuthorized(id, sharePrice, benchmark, 0);
            return 0;
        }
        uint256 cap = maxPerformanceFeeBps == 0 ? 1000 : maxPerformanceFeeBps;
        allowedBps = requestedBps > cap ? cap : requestedBps;
        poolHighWaterMark[id] = sharePrice;
        emit FeeAuthorized(id, sharePrice, benchmark, allowedBps);
    }

    function _curatorApproved(address who) internal view returns (bool) {
        if (registry != address(0)) return ICuratorRegistry(registry).isApproved(who);
        return verifiedScore[who] > 0;
    }
}
