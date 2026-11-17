// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SwapHelper
/// @notice Test utility that performs v4 swaps through the unlock callback pattern.
contract SwapHelper is IUnlockCallback {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable manager;

    struct SwapRequest {
        PoolKey key;
        IPoolManager.SwapParams params;
    }

    SwapRequest private request;
    int256 public lastDelta0;
    int256 public lastDelta1;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swap(PoolKey calldata key, IPoolManager.SwapParams calldata params) external returns (BalanceDelta delta) {
        request = SwapRequest(key, params);
        manager.unlock(abi.encode(this.swap.selector));
        delta = BalanceDelta.wrap(lastDelta0 | (lastDelta1 << 128));
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        SwapRequest memory req = request;
        BalanceDelta delta = manager.swap(req.key, req.params, "");
        lastDelta0 = delta.amount0();
        lastDelta1 = delta.amount1();

        if (delta.amount0() < 0) {
            uint256 amount = uint256(uint128(-delta.amount0()));
            manager.sync(req.key.currency0);
            IERC20(Currency.unwrap(req.key.currency0)).safeTransfer(address(manager), amount);
            manager.settle();
        } else if (delta.amount0() > 0) {
            manager.take(req.key.currency0, address(this), uint256(uint128(delta.amount0())));
        }

        if (delta.amount1() < 0) {
            uint256 amount = uint256(uint128(-delta.amount1()));
            manager.sync(req.key.currency1);
            IERC20(Currency.unwrap(req.key.currency1)).safeTransfer(address(manager), amount);
            manager.settle();
        } else if (delta.amount1() > 0) {
            manager.take(req.key.currency1, address(this), uint256(uint128(delta.amount1())));
        }

        return "";
    }
}
