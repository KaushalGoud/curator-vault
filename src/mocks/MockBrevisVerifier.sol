// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CuratorVaultHook} from "../CuratorVaultHook.sol";
import {CuratorRegistry} from "../CuratorRegistry.sol";

/// @title MockBrevisVerifier
/// @notice Stand-in for the Brevis proof callback. In the final build this is replaced by the
/// on-chain ZK proof verifier that writes curator performance scores from historical fee data.
/// It writes the score to the hook and approval to the registry so the full path is exercised.
contract MockBrevisVerifier {
    CuratorVaultHook public immutable hook;
    CuratorRegistry public registry;

    event ScoreSubmitted(address indexed curator, uint256 score);

    constructor(CuratorVaultHook _hook) {
        hook = _hook;
    }

    function setRegistry(CuratorRegistry _registry) external {
        require(address(registry) == address(0), "already set");
        registry = _registry;
    }

    function submitScore(address curator, uint256 score) external {
        hook.submitVerification(curator, score, "");
        if (address(registry) != address(0)) {
            registry.approve(curator, keccak256(abi.encodePacked(curator, score)));
        }
        emit ScoreSubmitted(curator, score);
    }
}
