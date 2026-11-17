// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {CuratorVaultHook} from "./CuratorVaultHook.sol";

/// @title CuratorVault
/// @notice ERC-4626-style managed liquidity vault. Depositors receive fungible shares backed by a
/// single Uniswap v4 concentrated liquidity position. Performance fees are charged on withdrawal
/// only when the share price exceeds a high-water mark, and the hook guarantees exits are honored.
contract CuratorVault is ERC20, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    error OnlyStrategy();
    error Unauthorized();
    error ZeroAmount();
    error ZeroShares();
    error InsufficientShares();
    error InvalidRange();
    error NoPosition();
    error DeadlineExpired();
    error MinSharesNotMet();
    error MinAmountNotMet();

    IPoolManager public immutable poolManager;
    CuratorVaultHook public immutable hook;
    PoolKey public poolKey;
    PoolId public poolId;

    address public curator;
    address public strategy;
    uint256 public performanceFeeBps;
    uint256 public highWaterMark;

    int24 public tickLower;
    int24 public tickUpper;
    uint128 public liquidity;
    bool public hasPosition;

    uint256 public invested0;
    uint256 public invested1;

    uint256 public benchmark0;
    uint256 public benchmark1;

    uint256 public totalPerformanceFees;

    bytes32 public constant SALT = keccak256("CuratorVault");

    event Deposited(address indexed user, uint256 amount0, uint256 amount1, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares, uint256 amount0, uint256 amount1, uint256 perfFee);
    event PositionAdded(int24 lower, int24 upper, uint128 liquidity, uint256 amount0, uint256 amount1);
    event PositionRemoved(uint128 liquidity, uint256 amount0, uint256 amount1);
    event Rebalanced(int24 oldLower, int24 oldUpper, int24 newLower, int24 newUpper);
    event CuratorSet(address curator);
    event StrategySet(address strategy);
    event HighWaterMarkUpdated(uint256 oldMark, uint256 newMark);

    enum Action {
        ADD_LIQUIDITY,
        REMOVE_LIQUIDITY
    }

    constructor(
        IPoolManager _poolManager,
        CuratorVaultHook _hook,
        PoolKey memory _poolKey,
        address _curator,
        uint256 _performanceFeeBps
    ) ERC20("CuratorVault Share", "CVLT") {
        require(address(_hook) != address(0), "zero hook");
        require(_curator != address(0), "zero curator");
        require(_performanceFeeBps <= 5000, "fee too high");
        poolManager = _poolManager;
        hook = _hook;
        poolKey = _poolKey;
        poolId = _poolKey.toId();
        curator = _curator;
        performanceFeeBps = _performanceFeeBps;
        highWaterMark = 1e18;
        _mint(address(this), 1);
    }

    modifier onlyStrategy() {
        if (msg.sender != strategy && msg.sender != curator) revert OnlyStrategy();
        _;
    }

    function setStrategy(address _strategy) external {
        if (msg.sender != curator) revert Unauthorized();
        strategy = _strategy;
        emit StrategySet(_strategy);
    }

    function setCurator(address _curator) external {
        if (msg.sender != curator) revert Unauthorized();
        curator = _curator;
        emit CuratorSet(_curator);
    }

    function setSupportedPool() external {
        if (msg.sender != curator) revert Unauthorized();
        hook.setSupportedPool(poolKey);
    }

    /// @notice Deposit both tokens and mint shares at current NAV per share.
    function deposit(uint256 amount0, uint256 amount1, uint256 minShares, uint256 deadline)
        external
        returns (uint256 shares)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (amount0 == 0 && amount1 == 0) revert ZeroAmount();
        IERC20(Currency.unwrap(poolKey.currency0)).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(Currency.unwrap(poolKey.currency1)).safeTransferFrom(msg.sender, address(this), amount1);

        benchmark0 += amount0;
        benchmark1 += amount1;

        uint256 value = amount0 + token1ToToken0(amount1);
        uint256 supply = totalSupply() - 1;
        uint256 nav = totalNav();
        if (supply == 0) {
            shares = value;
        } else {
            shares = (value * supply) / nav;
        }
        if (shares < minShares) revert MinSharesNotMet();
        if (shares == 0) revert ZeroShares();
        _mint(msg.sender, shares);

        uint256 price = navPerShare();
        if (price > highWaterMark) {
            uint256 old = highWaterMark;
            highWaterMark = price;
            emit HighWaterMarkUpdated(old, price);
        }
        emit Deposited(msg.sender, amount0, amount1, shares);
    }

    /// @notice Burn shares and withdraw a proportional share of the vault assets.
    function withdraw(uint256 shares, uint256 minAmount0, uint256 minAmount1, uint256 deadline)
        external
        returns (uint256 amount0, uint256 amount1, uint256 perfFee)
    {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (shares == 0) revert ZeroShares();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        uint256 supply = totalSupply() - 1;
        uint256 vault0 = IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(this));
        uint256 vault1 = IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(this));
        uint256 gross0 = (vault0 * shares) / supply;
        uint256 gross1 = (vault1 * shares) / supply;

        (gross0, gross1) = removeProportionalLiquidity(shares, supply, gross0, gross1);
        (gross0, perfFee) = chargePerformanceFee(shares, gross0, gross1);

        if (gross0 < minAmount0 || gross1 < minAmount1) revert MinAmountNotMet();
        benchmark0 -= (benchmark0 * shares) / supply;
        benchmark1 -= (benchmark1 * shares) / supply;
        _burn(msg.sender, shares);
        if (gross0 > 0) IERC20(Currency.unwrap(poolKey.currency0)).safeTransfer(msg.sender, gross0);
        if (gross1 > 0) IERC20(Currency.unwrap(poolKey.currency1)).safeTransfer(msg.sender, gross1);
        emit Withdrawn(msg.sender, shares, gross0, gross1, perfFee);
        return (gross0, gross1, perfFee);
    }

    function removeProportionalLiquidity(uint256 shares, uint256 supply, uint256 gross0, uint256 gross1)
        internal
        returns (uint256, uint256)
    {
        if (!hasPosition || liquidity == 0) return (gross0, gross1);
        uint128 liqToRemove = uint128((uint256(liquidity) * shares) / supply);
        if (liqToRemove == 0) return (gross0, gross1);
        bytes memory data = abi.encode(uint8(Action.REMOVE_LIQUIDITY), liqToRemove);
        poolManager.unlock(data);
        return (gross0 + lastRemoved0, gross1 + lastRemoved1);
    }

    function chargePerformanceFee(uint256 shares, uint256 gross0, uint256 gross1) internal returns (uint256, uint256) {
        uint256 price = navPerShare();
        uint256 benchmark = hodlPerShare();
        uint256 allowedBps = hook.authorizeFee(poolId, price, benchmark, performanceFeeBps);
        if (allowedBps == 0) return (gross0, 0);

        uint256 feePrice = ((price - benchmark) * allowedBps) / 10_000;
        uint256 feeValue = (feePrice * shares) / 1e18;
        uint256 grossValue = gross0 + token1ToToken0(gross1);
        uint256 perfFee = 0;
        if (grossValue > 0 && feeValue > 0) {
            uint256 feeToken0 = (feeValue * gross0) / grossValue;
            if (feeToken0 > 0 && feeToken0 <= gross0) {
                gross0 -= feeToken0;
                perfFee = feeToken0;
                totalPerformanceFees += feeToken0;
            }
        }
        uint256 old = highWaterMark;
        highWaterMark = price;
        emit HighWaterMarkUpdated(old, price);
        return (gross0, perfFee);
    }

    /// @notice Curator enters the managed position at a given range.
    function initializePosition(int24 lower, int24 upper, uint128 liq) external onlyStrategy {
        if (hasPosition) revert InvalidRange();
        if (lower >= upper) revert InvalidRange();
        if (liq == 0) revert ZeroAmount();
        tickLower = lower;
        tickUpper = upper;
        bytes memory data = abi.encode(uint8(Action.ADD_LIQUIDITY), liq, lower, upper, uint256(0), uint256(0));
        poolManager.unlock(data);
    }

    /// @notice Curator rebalances to a new range, removing the old position and adding a new one.
    function rebalance(int24 newLower, int24 newUpper, uint128 newLiquidity) external onlyStrategy {
        if (!hasPosition) revert NoPosition();
        if (newLower >= newUpper) revert InvalidRange();
        if (newLiquidity == 0) revert ZeroAmount();
        int24 oldLower = tickLower;
        int24 oldUpper = tickUpper;
        uint128 liq = liquidity;
        bytes memory removeData = abi.encode(uint8(Action.REMOVE_LIQUIDITY), liq);
        poolManager.unlock(removeData);
        tickLower = newLower;
        tickUpper = newUpper;
        bytes memory addData =
            abi.encode(uint8(Action.ADD_LIQUIDITY), newLiquidity, newLower, newUpper, uint256(0), uint256(0));
        poolManager.unlock(addData);
        emit Rebalanced(oldLower, oldUpper, newLower, newUpper);
    }

    uint256 public lastRemoved0;
    uint256 public lastRemoved1;

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        uint8 action = abi.decode(data, (uint8));
        if (action == uint8(Action.ADD_LIQUIDITY)) {
            (, uint128 liqDelta, int24 lower, int24 upper,,) =
                abi.decode(data, (uint8, uint128, int24, int24, uint256, uint256));
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: lower, tickUpper: upper, liquidityDelta: int256(uint256(liqDelta)), salt: SALT
            });
            (BalanceDelta delta,) = poolManager.modifyLiquidity(poolKey, params, "");
            uint256 pay0 = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
            uint256 pay1 = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;
            settle(poolKey.currency0, pay0);
            settle(poolKey.currency1, pay1);
            invested0 += pay0;
            invested1 += pay1;
            liquidity += liqDelta;
            hasPosition = true;
            emit PositionAdded(lower, upper, liqDelta, pay0, pay1);
        } else if (action == uint8(Action.REMOVE_LIQUIDITY)) {
            (, uint128 liq) = abi.decode(data, (uint8, uint128));
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(uint256(liq)), salt: SALT
            });
            (BalanceDelta delta,) = poolManager.modifyLiquidity(poolKey, params, "");
            uint256 take0 = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
            uint256 take1 = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;
            takeFromPool(poolKey.currency0, take0);
            takeFromPool(poolKey.currency1, take1);
            invested0 = invested0 > take0 ? invested0 - take0 : 0;
            invested1 = invested1 > take1 ? invested1 - take1 : 0;
            liquidity -= liq;
            if (liquidity == 0) hasPosition = false;
            lastRemoved0 = take0;
            lastRemoved1 = take1;
            emit PositionRemoved(liq, take0, take1);
        }
        return "";
    }

    function settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    function takeFromPool(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.take(currency, address(this), amount);
    }

    function token1ToToken0(uint256 amount1) public view returns (uint256) {
        uint256 priceX192 = hook.getEmaPriceX192(poolId);
        if (priceX192 == 0) return amount1;
        return FullMath.mulDiv(amount1, 1 << 192, priceX192);
    }

    function totalNav() public view returns (uint256) {
        uint256 balance0 = IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(this));
        uint256 balance1 = IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(this));
        return balance0 + balance1 + invested0 + token1ToToken0(invested1);
    }

    function navPerShare() public view returns (uint256) {
        uint256 supply = totalSupply() - 1;
        if (supply == 0) return 1e18;
        return (totalNav() * 1e18) / supply;
    }

    function token0ToToken1(uint256 amount0) public view returns (uint256) {
        uint256 priceX192 = hook.getEmaPriceX192(poolId);
        if (priceX192 == 0) return amount0;
        return (amount0 * priceX192) >> 192;
    }

    /// @notice What depositors would have if they simply held their deposited tokens,
    /// valued at the hook's EMA price rather than spot.
    function hodlPerShare() public view returns (uint256) {
        uint256 supply = totalSupply() - 1;
        if (supply == 0) return 1e18;
        uint256 hodlValue = benchmark0 + token1ToToken0(benchmark1);
        return (hodlValue * 1e18) / supply;
    }
}
