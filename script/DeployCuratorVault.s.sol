// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {CREATE2Deployer} from "../src/mocks/CREATE2Deployer.sol";
import {CuratorVaultHook} from "../src/CuratorVaultHook.sol";
import {CuratorVault} from "../src/CuratorVault.sol";
import {SimpleRangeStrategy} from "../src/SimpleRangeStrategy.sol";
import {MockBrevisVerifier} from "../src/mocks/MockBrevisVerifier.sol";
import {CuratorRegistry} from "../src/CuratorRegistry.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Deploy CuratorVault stack with a permission-mined hook address.
contract DeployCuratorVault is Script {
    uint160 constant HOOK_FLAGS = 0xfc0;

    struct Deployment {
        PoolManager manager;
        TestERC20 token0;
        TestERC20 token1;
        CuratorVaultHook hook;
        CuratorVault vault;
        SimpleRangeStrategy strategy;
        MockBrevisVerifier verifier;
        CuratorRegistry registry;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployerAddr = vm.addr(deployerKey);
        vm.startBroadcast(deployerKey);

        Deployment memory d;
        d.manager = new PoolManager(deployerAddr);

        TestERC20 t0 = new TestERC20(1e30);
        TestERC20 t1 = new TestERC20(1e30);
        if (address(t0) > address(t1)) {
            (t0, t1) = (t1, t0);
        }
        d.token0 = t0;
        d.token1 = t1;

        uint256 minRebalanceInterval = vm.envOr("MIN_REBALANCE_INTERVAL", uint256(1 hours));
        uint256 strategyCooldown = vm.envOr("STRATEGY_COOLDOWN", uint256(1 hours));

        d.hook = _deployHook(deployerAddr, d.manager, minRebalanceInterval);

        PoolKey memory key = _makePoolKey(address(t0), address(t1), d.hook);
        d.manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        d.vault = new CuratorVault(d.manager, d.hook, key, deployerAddr, 1000);
        d.strategy = new SimpleRangeStrategy(d.vault, deployerAddr, 1000, strategyCooldown, 500);
        d.verifier = new MockBrevisVerifier(d.hook);
        d.registry = new CuratorRegistry(IERC20(address(t0)), deployerAddr, 100e18);

        _wire(d);
        d.vault.setSupportedPool();
        vm.stopBroadcast();

        console2.log("PoolManager:", address(d.manager));
        console2.log("Token0:", address(d.token0));
        console2.log("Token1:", address(d.token1));
        console2.log("Hook:", address(d.hook));
        console2.log("Vault:", address(d.vault));
        console2.log("Strategy:", address(d.strategy));
        console2.log("Verifier:", address(d.verifier));
        console2.log("Registry:", address(d.registry));
    }

    function _deployHook(address owner, PoolManager manager, uint256 minRebalanceInterval)
        internal
        returns (CuratorVaultHook hook)
    {
        bytes memory code = abi.encodePacked(
            type(CuratorVaultHook).creationCode,
            abi.encode(
                owner,
                address(manager),
                uint24(500),
                uint24(3000),
                uint24(20),
                int24(1000),
                minRebalanceInterval,
                uint256(20)
            )
        );
        CREATE2Deployer create2 = new CREATE2Deployer();
        bytes32 hash = keccak256(code);
        for (uint256 i = 0; i < 1_000_000; i++) {
            bytes32 s = bytes32(i);
            address predicted = vm.computeCreate2Address(s, hash, address(create2));
            if (uint160(predicted) & 0x3fff == HOOK_FLAGS) {
                return CuratorVaultHook(create2.deploy(s, code));
            }
        }
        revert("no CREATE2 salt found");
    }

    function _makePoolKey(address t0, address t1, CuratorVaultHook hook) internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
    }

    function _wire(Deployment memory d) internal {
        d.hook.setVault(address(d.vault));
        d.hook.setStrategy(address(d.strategy));
        d.hook.setVerifier(address(d.verifier));
        d.hook.setRegistry(address(d.registry));
        d.hook.setMaxPerformanceFeeBps(1000);
        d.verifier.setRegistry(d.registry);
        d.registry.setVerifier(address(d.verifier));
        d.vault.setStrategy(address(d.strategy));
    }
}
