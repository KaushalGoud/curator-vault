// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BrevisAppZkOnly} from "./brevis/BrevisAppZkOnly.sol";

interface ICuratorRegistryApprover {
    function approve(address curator, bytes32 claim) external;
}

/// @title BrevisCuratorVerifier
/// @notice Accepts ZK-attested Brevis results and approves curators in the stake registry.
/// The proven claim is deliberately small and honest: an approved strategy address emitted
/// at least `minRebalances` RebalanceExecuted events from this hook within a bounded block range.
/// This does not claim proved outperformance; outperformance is measured separately by the vault HODL benchmark.
contract BrevisCuratorVerifier is BrevisAppZkOnly {
    error Unauthorized();
    error InvalidVk();
    error InvalidHook();
    error InsufficientRebalances();
    error InvalidBlockRange();
    error ClaimAlreadyUsed();
    error ZeroAddress();

    address public owner;
    bytes32 public vkHash;
    ICuratorRegistryApprover public registry;
    address public immutable hook;
    uint64 public minRebalances;
    uint32 public maxBlockRange;

    mapping(bytes32 => bool) public usedClaim;

    event VerifierConfigured(bytes32 vkHash, uint64 minRebalances, uint32 maxBlockRange);
    event RegistrySet(address registry);
    event CuratorProofAccepted(
        address indexed curator, uint64 rebalances, uint32 fromBlock, uint32 toBlock, bytes32 claim
    );

    constructor(address _brevisRequest, address _owner, address _hook, uint64 _minRebalances, uint32 _maxBlockRange)
        BrevisAppZkOnly(_brevisRequest)
    {
        if (_owner == address(0) || _brevisRequest == address(0) || _hook == address(0)) revert ZeroAddress();
        owner = _owner;
        hook = _hook;
        minRebalances = _minRebalances;
        maxBlockRange = _maxBlockRange;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    function setVkHash(bytes32 _vkHash) external onlyOwner {
        if (_vkHash == bytes32(0)) revert InvalidVk();
        vkHash = _vkHash;
        emit VerifierConfigured(_vkHash, minRebalances, maxBlockRange);
    }

    function setRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert ZeroAddress();
        if (address(registry) != address(0)) revert Unauthorized();
        registry = ICuratorRegistryApprover(_registry);
        emit RegistrySet(_registry);
    }

    function setThresholds(uint64 _minRebalances, uint32 _maxBlockRange) external onlyOwner {
        minRebalances = _minRebalances;
        maxBlockRange = _maxBlockRange;
        emit VerifierConfigured(vkHash, _minRebalances, _maxBlockRange);
    }

    function handleProofResult(bytes32 _vkHash, bytes calldata _appCircuitOutput) internal override {
        if (_vkHash != vkHash || vkHash == bytes32(0)) revert InvalidVk();

        (address provenHook, address curator, uint64 rebalances, uint32 fromBlock, uint32 toBlock) =
            decodeOutput(_appCircuitOutput);
        if (provenHook != hook) revert InvalidHook();
        if (rebalances < minRebalances) revert InsufficientRebalances();
        if (toBlock <= fromBlock || uint256(toBlock) - uint256(fromBlock) > maxBlockRange) revert InvalidBlockRange();

        bytes32 claim = keccak256(abi.encodePacked(curator, rebalances, fromBlock, toBlock));
        if (usedClaim[claim]) revert ClaimAlreadyUsed();
        usedClaim[claim] = true;

        emit CuratorProofAccepted(curator, rebalances, fromBlock, toBlock, claim);
        registry.approve(curator, claim);
    }

    /// @dev Circuit outputs: OutputAddress(hook), OutputAddress(strategy), OutputUint(64, count),
    /// OutputUint(32, minBlock), OutputUint(32, maxBlock).
    function decodeOutput(bytes calldata output)
        public
        pure
        returns (address provenHook, address curator, uint64 rebalances, uint32 fromBlock, uint32 toBlock)
    {
        provenHook = address(bytes20(output[0:20]));
        curator = address(bytes20(output[20:40]));
        rebalances = uint64(bytes8(output[40:48]));
        fromBlock = uint32(bytes4(output[48:52]));
        toBlock = uint32(bytes4(output[52:56]));
    }
}
