// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {CuratorRegistry} from "../src/CuratorRegistry.sol";
import {BrevisCuratorVerifier} from "../src/BrevisCuratorVerifier.sol";

contract BrevisCuratorVerifierTest is Test {
    TestERC20 token;
    CuratorRegistry registry;
    BrevisCuratorVerifier verifier;

    address brevisRequest = makeAddr("brevisRequest");
    address hook = makeAddr("hook");
    address curator = makeAddr("curator");
    address outsider = makeAddr("outsider");
    bytes32 vkHash = keccak256("CuratorVault Brevis vk");

    function setUp() public {
        token = new TestERC20(1e30);
        registry = new CuratorRegistry(IERC20(address(token)), address(this), 100e18);
        verifier = new BrevisCuratorVerifier(brevisRequest, address(this), hook, 2, 1000);

        registry.setVerifier(address(verifier));
        verifier.setRegistry(address(registry));
        verifier.setVkHash(vkHash);

        token.transfer(curator, 200e18);
        vm.startPrank(curator);
        token.approve(address(registry), 200e18);
        registry.stake(200e18);
        vm.stopPrank();
    }

    function _proof(address who, uint64 count, uint32 fromBlock, uint32 toBlock) internal view returns (bytes memory) {
        return abi.encodePacked(hook, who, count, fromBlock, toBlock);
    }

    function test_ValidProofApprovesCurator() public {
        bytes memory proof = _proof(curator, 3, 100, 200);
        vm.prank(brevisRequest);
        verifier.brevisCallback(vkHash, proof);
        assertTrue(registry.isApproved(curator));
    }

    function test_OnlyBrevisRequestCanCallback() public {
        vm.prank(outsider);
        vm.expectRevert("invalid caller");
        verifier.brevisCallback(vkHash, _proof(curator, 3, 100, 200));
    }

    function test_InvalidVkRejected() public {
        vm.prank(brevisRequest);
        vm.expectRevert(BrevisCuratorVerifier.InvalidVk.selector);
        verifier.brevisCallback(keccak256("wrong"), _proof(curator, 3, 100, 200));
    }

    function test_InvalidHookRejected() public {
        bytes memory proof = abi.encodePacked(outsider, curator, uint64(3), uint32(100), uint32(200));
        vm.prank(brevisRequest);
        vm.expectRevert(BrevisCuratorVerifier.InvalidHook.selector);
        verifier.brevisCallback(vkHash, proof);
    }

    function test_InsufficientRebalancesRejected() public {
        vm.prank(brevisRequest);
        vm.expectRevert(BrevisCuratorVerifier.InsufficientRebalances.selector);
        verifier.brevisCallback(vkHash, _proof(curator, 1, 100, 200));
    }

    function test_InvalidBlockRangeRejected() public {
        vm.prank(brevisRequest);
        vm.expectRevert(BrevisCuratorVerifier.InvalidBlockRange.selector);
        verifier.brevisCallback(vkHash, _proof(curator, 3, 100, 2000));
    }

    function test_ClaimCannotBeReused() public {
        bytes memory proof = _proof(curator, 3, 100, 200);
        vm.prank(brevisRequest);
        verifier.brevisCallback(vkHash, proof);

        vm.prank(brevisRequest);
        vm.expectRevert(BrevisCuratorVerifier.ClaimAlreadyUsed.selector);
        verifier.brevisCallback(vkHash, proof);
    }
}
