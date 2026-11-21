// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract CuratorRegistry {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error StakeTooLow();
    error AlreadyApproved();
    error NotApproved();
    error ZeroAddress();
    error InvalidScore();
    error VaultNotRegistered();

    IERC20 public immutable stakeToken;
    address public owner;
    address public reporter;
    uint256 public minStake;
    uint256 public minScore;
    uint256 public initialScore;

    mapping(address => uint256) public stakeOf;
    mapping(address => bool) public approved;
    mapping(address => int256) public reputation;
    mapping(address => uint256) public observations;
    mapping(address => address) public vaultOf;
    mapping(address => bool) public vaultRegistered;

    event ReporterSet(address reporter);
    event MinStakeUpdated(uint256 minStake);
    event MinScoreUpdated(uint256 minScore);
    event Staked(address indexed curator, uint256 amount);
    event CuratorApproved(address indexed curator);
    event CuratorRevoked(address indexed curator);
    event VaultRegistered(address indexed curator, address indexed vault);
    event ReputationUpdated(address indexed curator, int256 alphaBps, int256 score, uint256 aumCap);

    constructor(IERC20 _stakeToken, address _owner, uint256 _minStake, uint256 _minScore, uint256 _initialScore) {
        if (address(_stakeToken) == address(0) || _owner == address(0)) revert ZeroAddress();
        if (_initialScore < _minScore) revert InvalidScore();
        stakeToken = _stakeToken;
        owner = _owner;
        minStake = _minStake;
        minScore = _minScore;
        initialScore = _initialScore;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyReporter() {
        if (msg.sender != reporter || reporter == address(0)) revert Unauthorized();
        _;
    }

    function setReporter(address _reporter) external onlyOwner {
        if (_reporter == address(0)) revert ZeroAddress();
        reporter = _reporter;
        emit ReporterSet(_reporter);
    }

    function setMinStake(uint256 _minStake) external onlyOwner {
        minStake = _minStake;
        emit MinStakeUpdated(_minStake);
    }

    function setMinScore(uint256 _minScore) external onlyOwner {
        minScore = _minScore;
        emit MinScoreUpdated(_minScore);
    }

    function stake(uint256 amount) external {
        _stake(msg.sender, amount);
    }

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

    function approve(address curator) external onlyOwner {
        if (stakeOf[curator] < minStake) revert StakeTooLow();
        if (approved[curator]) revert AlreadyApproved();
        approved[curator] = true;
        reputation[curator] = int256(initialScore);
        emit CuratorApproved(curator);
    }

    function revoke(address curator) external onlyOwner {
        _revoke(curator);
    }

    function _revoke(address curator) internal {
        if (!approved[curator]) revert NotApproved();
        approved[curator] = false;
        emit CuratorRevoked(curator);
    }

    function registerVault(address curator, address vault) external onlyOwner {
        if (curator == address(0) || vault == address(0)) revert ZeroAddress();
        if (vaultRegistered[vault]) revert AlreadyApproved();
        vaultOf[curator] = vault;
        vaultRegistered[vault] = true;
        emit VaultRegistered(curator, vault);
    }

    function recordPerformance(address curator, address vault, int256 alphaBps) external onlyReporter {
        if (vaultOf[curator] != vault) revert VaultNotRegistered();
        if (!approved[curator]) revert NotApproved();

        int256 bounded = alphaBps;
        if (bounded > 1000) bounded = 1000;
        if (bounded < -1000) bounded = -1000;

        int256 next = (reputation[curator] * 9 + bounded) / 10;
        if (next < 0) next = 0;
        reputation[curator] = next;
        observations[curator] += 1;

        if (next < int256(minScore)) _revoke(curator);
        emit ReputationUpdated(curator, bounded, next, aumCap(curator));
    }

    function aumCap(address curator) public view returns (uint256) {
        if (!approved[curator]) return 0;
        uint256 positiveScore = reputation[curator] > 0 ? uint256(reputation[curator]) : 0;
        return (stakeOf[curator] * (200 + positiveScore)) / 100;
    }

    function canManage(address curator, address vault, uint256 aum) external view returns (bool) {
        return vaultOf[curator] == vault && approved[curator] && aum <= aumCap(curator);
    }

    function isApproved(address curator) external view returns (bool) {
        return approved[curator];
    }
}
