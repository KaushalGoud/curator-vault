// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CuratorRegistry
/// @notice Stake-and-prove approval layer for curators. A curator commits to one address by staking
/// tokens there; a verifier (Brevis or a disclosed mock) approves only after a valid proof.
/// The hook reads `isApproved` before allowing any liquidity action.
contract CuratorRegistry {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error StakeTooLow();
    error AlreadyApproved();
    error NotApproved();
    error ZeroAddress();

    IERC20 public immutable stakeToken;
    address public owner;
    address public verifier;
    uint256 public minStake;

    mapping(address => uint256) public stakeOf;
    mapping(address => bool) public approved;
    mapping(address => bytes32) public proofClaim;

    event VerifierSet(address verifier);
    event MinStakeUpdated(uint256 minStake);
    event Staked(address indexed curator, uint256 amount);
    event CuratorApproved(address indexed curator, bytes32 claim);
    event CuratorRevoked(address indexed curator);

    constructor(IERC20 _stakeToken, address _owner, uint256 _minStake) {
        if (address(_stakeToken) == address(0) || _owner == address(0)) revert ZeroAddress();
        stakeToken = _stakeToken;
        owner = _owner;
        minStake = _minStake;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyVerifier() {
        if (msg.sender != verifier) revert Unauthorized();
        _;
    }

    function setVerifier(address _verifier) external onlyOwner {
        if (_verifier == address(0)) revert ZeroAddress();
        verifier = _verifier;
        emit VerifierSet(_verifier);
    }

    function setMinStake(uint256 _minStake) external onlyOwner {
        minStake = _minStake;
        emit MinStakeUpdated(_minStake);
    }

    /// @notice Curator stakes tokens from the address they commit to.
    function stake(uint256 amount) external {
        _stake(msg.sender, amount);
    }

    /// @notice Stake on behalf of a curator address, e.g. a strategy module deployed by the curator.
    function stakeFor(address curator, uint256 amount) external {
        if (curator == address(0)) revert ZeroAddress();
        _stake(curator, amount);
    }

    function _stake(address curator, uint256 amount) internal {
        if (amount == 0) revert StakeTooLow();
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        stakeOf[curator] += amount;
        emit Staked(curator, amount);
    }

    /// @notice Verifier approves a curator only when the stake requirement is met.
    /// @param claim Hash of the exact claim that was proven (e.g. blocks X..Y and benchmark result).
    function approve(address curator, bytes32 claim) external onlyVerifier {
        if (stakeOf[curator] < minStake) revert StakeTooLow();
        if (approved[curator]) revert AlreadyApproved();
        approved[curator] = true;
        proofClaim[curator] = claim;
        emit CuratorApproved(curator, claim);
    }

    /// @notice Verifier can revoke an approval (stake stays locked; no admin can withdraw it).
    function revoke(address curator) external onlyVerifier {
        if (!approved[curator]) revert NotApproved();
        approved[curator] = false;
        emit CuratorRevoked(curator);
    }

    function isApproved(address curator) external view returns (bool) {
        return approved[curator];
    }
}
