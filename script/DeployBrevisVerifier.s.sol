// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {BrevisCuratorVerifier} from "../src/BrevisCuratorVerifier.sol";
import {CuratorRegistry} from "../src/CuratorRegistry.sol";

contract DeployBrevisVerifier is Script {
    address constant DEFAULT_BREVIS_REQUEST = 0x841ce48F9446C8E281D3F1444cB859b4A6D0738C;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployerAddr = vm.addr(deployerKey);
        address brevisRequest = vm.envOr("BREVIS_REQUEST", DEFAULT_BREVIS_REQUEST);
        address registryAddr = vm.envAddress("REGISTRY");
        address hookAddr = vm.envAddress("HOOK");
        bytes32 vkHash = vm.envOr("BREVIS_VK_HASH", bytes32(0));
        uint64 minRebalances = uint64(vm.envOr("MIN_REBALANCES", uint256(2)));
        uint32 maxBlockRange = uint32(vm.envOr("MAX_BLOCK_RANGE", uint256(100000)));

        vm.startBroadcast(deployerKey);
        BrevisCuratorVerifier verifier =
            new BrevisCuratorVerifier(brevisRequest, deployerAddr, hookAddr, minRebalances, maxBlockRange);
        verifier.setRegistry(registryAddr);
        if (vkHash != bytes32(0)) verifier.setVkHash(vkHash);
        CuratorRegistry(registryAddr).setVerifier(address(verifier));
        vm.stopBroadcast();

        console2.log("BrevisRequest:", brevisRequest);
        console2.log("BrevisVerifier:", address(verifier));
        console2.log("Registry:", registryAddr);
        console2.log("Hook:", hookAddr);
        console2.log("VkHash:", vm.toString(vkHash));
    }
}
