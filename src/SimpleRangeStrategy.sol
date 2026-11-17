// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CuratorVault} from "./CuratorVault.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title SimpleRangeStrategy
/// @notice Curator-controlled rebalancing module with on-chain guardrails: a maximum range width,
/// a cooldown between rebalances, and a maximum allowed drift of the range center from spot.
contract SimpleRangeStrategy {
    error OnlyCurator();
    error DriftTooLarge();
    error RangeTooWide();
    error CooldownActive();
    error InvalidRange();

    CuratorVault public immutable vault;
    address public immutable curator;
    int24 public maxRangeWidth;
    uint256 public rebalanceCooldown;
    int24 public maxCenterDriftTicks;
    uint256 public lastRebalance;

    event ParametersUpdated(int24 maxRangeWidth, uint256 rebalanceCooldown, int24 maxCenterDriftTicks);
    event StrategyRebalanced(int24 lower, int24 upper, uint128 liquidity);

    constructor(
        CuratorVault _vault,
        address _curator,
        int24 _maxRangeWidth,
        uint256 _rebalanceCooldown,
        int24 _maxCenterDriftTicks
    ) {
        vault = _vault;
        curator = _curator;
        maxRangeWidth = _maxRangeWidth;
        rebalanceCooldown = _rebalanceCooldown;
        maxCenterDriftTicks = _maxCenterDriftTicks;
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert OnlyCurator();
        _;
    }

    function setParameters(int24 _maxRangeWidth, uint256 _rebalanceCooldown, int24 _maxCenterDriftTicks)
        external
        onlyCurator
    {
        maxRangeWidth = _maxRangeWidth;
        rebalanceCooldown = _rebalanceCooldown;
        maxCenterDriftTicks = _maxCenterDriftTicks;
        emit ParametersUpdated(_maxRangeWidth, _rebalanceCooldown, _maxCenterDriftTicks);
    }

    function currentTick() public view returns (int24) {
        (, int24 tick,,) = StateLibrary.getSlot0(vault.poolManager(), vault.poolId());
        return tick;
    }

    function initialize(int24 lower, int24 upper, uint128 liquidity) external onlyCurator {
        if (lower >= upper) revert InvalidRange();
        if (upper - lower > maxRangeWidth) revert RangeTooWide();
        vault.initializePosition(lower, upper, liquidity);
        lastRebalance = block.timestamp;
    }

    function rebalance(int24 lower, int24 upper, uint128 liquidity) external onlyCurator {
        if (lower >= upper) revert InvalidRange();
        if (upper - lower > maxRangeWidth) revert RangeTooWide();
        if (block.timestamp < lastRebalance + rebalanceCooldown) revert CooldownActive();
        int24 tick = currentTick();
        int24 center = (lower + upper) / 2;
        int24 drift = center > tick ? center - tick : tick - center;
        if (drift > maxCenterDriftTicks) revert DriftTooLarge();
        vault.rebalance(lower, upper, liquidity);
        lastRebalance = block.timestamp;
        emit StrategyRebalanced(lower, upper, liquidity);
    }

    function suggestedRange(int24 halfWidth) external view returns (int24 lower, int24 upper) {
        int24 tick = currentTick();
        lower = tick - halfWidth;
        upper = tick + halfWidth;
    }
}
