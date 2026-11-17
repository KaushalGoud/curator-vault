// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {CREATE2Deployer} from "../src/mocks/CREATE2Deployer.sol";
import {CuratorVaultHook} from "../src/CuratorVaultHook.sol";
import {CuratorVault} from "../src/CuratorVault.sol";
import {SimpleRangeStrategy} from "../src/SimpleRangeStrategy.sol";
import {MockBrevisVerifier} from "../src/mocks/MockBrevisVerifier.sol";
import {SwapHelper} from "../src/mocks/SwapHelper.sol";
import {CuratorRegistry} from "../src/CuratorRegistry.sol";

contract CuratorVaultTest is Test {
    PoolManager manager;
    CuratorVaultHook hook;
    CuratorVault vault;
    SimpleRangeStrategy strategy;
    MockBrevisVerifier verifier;
    CuratorRegistry registry;
    TestERC20 token0;
    TestERC20 token1;

    address curator = makeAddr("curator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address outsider = makeAddr("outsider");

    PoolKey key;

    uint160 constant HOOK_FLAGS = 0xfc0;

    function setUp() public {
        manager = new PoolManager(address(this));
        token0 = new TestERC20(1e30);
        token1 = new TestERC20(1e30);
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        bytes memory hookCode = abi.encodePacked(
            type(CuratorVaultHook).creationCode,
            abi.encode(
                address(this),
                address(manager),
                uint24(500),
                uint24(3000),
                uint24(20),
                int24(1000),
                uint256(1 hours),
                uint256(20)
            )
        );
        hook = CuratorVaultHook(_mineAndDeploy(hookCode, HOOK_FLAGS));

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        vault = new CuratorVault(manager, hook, key, curator, 1000);
        strategy = new SimpleRangeStrategy(vault, curator, 1000, 1 hours, 500);
        verifier = new MockBrevisVerifier(hook);
        registry = new CuratorRegistry(IERC20(address(token0)), address(this), 100e18);

        vm.startPrank(curator);
        vault.setStrategy(address(strategy));
        vm.stopPrank();

        hook.setVault(address(vault));
        hook.setStrategy(address(strategy));
        hook.setVerifier(address(verifier));
        hook.setRegistry(address(registry));
        hook.setMaxPerformanceFeeBps(1000);
        verifier.setRegistry(registry);
        registry.setVerifier(address(verifier));
        vm.prank(curator);
        vault.setSupportedPool();

        token0.transfer(alice, 100_000e18);
        token1.transfer(alice, 100_000e18);
        token0.transfer(bob, 100_000e18);
        token1.transfer(bob, 100_000e18);
        token0.transfer(curator, 100_000e18);
        token1.transfer(curator, 100_000e18);
    }

    function _mineAndDeploy(bytes memory code, uint160 flags) internal returns (address) {
        CREATE2Deployer deployer = new CREATE2Deployer();
        bytes32 hash = keccak256(code);
        for (uint256 salt = 0; salt < 1_000_000; salt++) {
            bytes32 s = bytes32(salt);
            address predicted = deployer.computeAddress(s, hash);
            if (uint160(predicted) & 0x3fff == flags) {
                return deployer.deploy(s, code);
            }
        }
        revert("no salt found");
    }

    function _stake(address who, uint256 amount) internal {
        token0.transfer(who, amount);
        vm.startPrank(who);
        token0.approve(address(registry), amount);
        registry.stake(amount);
        vm.stopPrank();
    }

    function _verifyCurator() internal {
        _stake(curator, 200e18);
        _stake(address(strategy), 200e18);
        verifier.submitScore(curator, 90);
        verifier.submitScore(address(strategy), 90);
    }

    function test_HookPermissions() public view {
        assertTrue(uint160(address(hook)) & HOOK_FLAGS == HOOK_FLAGS, "hook flags");
    }

    function test_SetUpWiring() public view {
        assertEq(address(vault.hook()), address(hook));
        assertEq(address(strategy.vault()), address(vault));
        assertEq(vault.curator(), curator);
        assertEq(hook.verifier(), address(verifier));
    }

    function test_VerificationGate() public {
        assertEq(hook.verifiedScore(address(strategy)), 0);
        _verifyCurator();
        assertEq(hook.verifiedScore(address(strategy)), 90);
        assertEq(hook.verifiedScore(curator), 90);
    }

    function test_DepositMintsShares() public {
        vm.startPrank(alice);
        token0.approve(address(vault), 10_000e18);
        token1.approve(address(vault), 10_000e18);
        uint256 shares = vault.deposit(10_000e18, 10_000e18, 1, block.timestamp + 1 hours);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertGt(vault.navPerShare(), 0);
        vm.stopPrank();
    }

    function test_DynamicFeeIncreasesWithDeviation() public view {
        uint24 fee = hook.computeFee(TickMath.getSqrtPriceAtTick(100), TickMath.getSqrtPriceAtTick(0));
        assertGt(fee, hook.baseFee());
        assertLe(fee, hook.maxFee());
    }

    function test_Gating_UnverifiedStrategyCannotAddLiquidity() public {
        vm.startPrank(alice);
        token0.approve(address(vault), 20_000e18);
        token1.approve(address(vault), 20_000e18);
        vault.deposit(10_000e18, 10_000e18, 1, block.timestamp + 1 hours);
        vm.stopPrank();

        vm.startPrank(curator);
        vm.expectRevert();
        strategy.initialize(-60, 60, 3e24);
        vm.stopPrank();

        assertFalse(vault.hasPosition());
    }

    function test_Gating_RangeTooWide() public {
        _verifyCurator();
        vm.startPrank(curator);
        vm.expectRevert(SimpleRangeStrategy.RangeTooWide.selector);
        strategy.initialize(-1200, 1200, 3e24);
        vm.stopPrank();
    }

    function test_Gating_NonCuratorCannotRebalance() public {
        vm.prank(alice);
        vm.expectRevert(SimpleRangeStrategy.OnlyCurator.selector);
        strategy.rebalance(-60, 60, 3e24);
    }

    function test_InitializePositionAndWithdraw() public {
        _verifyCurator();
        vm.startPrank(alice);
        token0.approve(address(vault), 20_000e18);
        token1.approve(address(vault), 20_000e18);
        uint256 shares = vault.deposit(10_000e18, 10_000e18, 1, block.timestamp + 1 hours);
        vm.stopPrank();

        vm.prank(curator);
        strategy.initialize(-60, 60, 3e24);
        assertTrue(vault.hasPosition());
        assertGt(vault.liquidity(), 0);

        uint256 nav = vault.navPerShare();
        assertGt(nav, 0);

        vm.prank(alice);
        (uint256 a0, uint256 a1, uint256 perfFee) = vault.withdraw(shares, 0, 0, block.timestamp + 1 hours);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(perfFee, 0);
        assertFalse(vault.hasPosition());
    }

    function test_DynamicFeeAppliedOnSwap() public {
        _verifyCurator();
        vm.startPrank(alice);
        token0.approve(address(vault), 20_000e18);
        token1.approve(address(vault), 20_000e18);
        vault.deposit(10_000e18, 10_000e18, 1, block.timestamp + 1 hours);
        vm.stopPrank();

        SwapHelper swapper = new SwapHelper(manager);
        token0.transfer(address(swapper), 1_000e18);

        vm.prank(curator);
        strategy.initialize(-60, 60, 3e24);

        uint24 feeBefore = hook.computeFee(TickMath.getSqrtPriceAtTick(0), TickMath.getSqrtPriceAtTick(0));

        vm.expectEmit(true, false, false, false);
        emit DynamicFeeSet(PoolId.unwrap(PoolIdLibrary.toId(key)), feeBefore);
        swapper.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: 100e18, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-120)
            })
        );

        assertGe(hook.poolEmaPrice(PoolIdLibrary.toId(key)), 0);
    }

    function test_RebalanceCooldown() public {
        _verifyCurator();
        vm.startPrank(alice);
        token0.approve(address(vault), 20_000e18);
        token1.approve(address(vault), 20_000e18);
        vault.deposit(10_000e18, 10_000e18, 1, block.timestamp + 1 hours);
        vm.stopPrank();

        vm.prank(curator);
        strategy.initialize(-60, 60, 3e24);

        vm.warp(block.timestamp + 60);
        vm.prank(curator);
        vm.expectRevert(SimpleRangeStrategy.CooldownActive.selector);
        strategy.rebalance(-60, 60, 3e24);
    }

    function test_PerformanceFee_NoFeeBelowHWM() public {
        _verifyCurator();
        vm.startPrank(alice);
        token0.approve(address(vault), 20_000e18);
        token1.approve(address(vault), 20_000e18);
        uint256 shares = vault.deposit(10_000e18, 10_000e18, 1, block.timestamp + 1 hours);
        vm.stopPrank();

        uint256 hwm = vault.highWaterMark();
        assertEq(hwm, 1e18);

        vm.prank(alice);
        (,, uint256 perfFee) = vault.withdraw(shares / 2, 0, 0, block.timestamp + 1 hours);
        assertEq(perfFee, 0);
    }

    function test_Registry_StakeRequired() public {
        vm.expectRevert(CuratorRegistry.StakeTooLow.selector);
        verifier.submitScore(address(strategy), 90);
        assertFalse(registry.isApproved(address(strategy)));
    }

    function test_Registry_ValidProofApproves() public {
        _stake(address(strategy), 200e18);
        assertFalse(registry.isApproved(address(strategy)));
        verifier.submitScore(address(strategy), 90);
        assertTrue(registry.isApproved(address(strategy)));
        assertEq(registry.stakeOf(address(strategy)), 200e18);
    }

    function test_Registry_StakeForCurator() public {
        token0.approve(address(registry), 200e18);
        registry.stakeFor(address(strategy), 200e18);
        assertEq(registry.stakeOf(address(strategy)), 200e18);
        verifier.submitScore(address(strategy), 90);
        assertTrue(registry.isApproved(address(strategy)));
    }

    function test_Registry_RevokedCuratorBlocked() public {
        _verifyCurator();
        vm.prank(address(verifier));
        registry.revoke(address(strategy));
        assertFalse(registry.isApproved(address(strategy)));

        vm.startPrank(alice);
        token0.approve(address(vault), 20_000e18);
        token1.approve(address(vault), 20_000e18);
        vault.deposit(10_000e18, 10_000e18, 1, block.timestamp + 1 hours);
        vm.stopPrank();

        vm.prank(curator);
        vm.expectRevert();
        strategy.initialize(-60, 60, 3e24);
    }

    function testFuzz_ComputeFeeWithinBounds(uint160 ref, uint160 delta) public view {
        vm.assume(ref > 0);
        uint160 current = ref > type(uint160).max - delta ? type(uint160).max : ref + delta;
        uint24 fee = hook.computeFee(current, ref);
        assertGe(fee, hook.baseFee());
        assertLe(fee, hook.maxFee());
    }

    function testFuzz_DepositShareAccounting(uint256 amount) public {
        vm.assume(amount >= 1e18 && amount <= 1000e18);
        vm.startPrank(alice);
        token0.approve(address(vault), amount);
        token1.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, amount, 1, block.timestamp + 1 hours);
        assertEq(vault.balanceOf(alice), shares);
        assertGt(vault.navPerShare(), 0);
        vm.stopPrank();
    }

    function test_Invariant_NavMatchesDeposits() public {
        vm.startPrank(alice);
        token0.approve(address(vault), 20_000e18);
        token1.approve(address(vault), 20_000e18);
        vault.deposit(10_000e18, 10_000e18, 1, block.timestamp + 1 hours);
        vm.stopPrank();
        assertEq(vault.totalNav(), 20_000e18);
        assertEq(vault.hodlPerShare(), 1e18);
    }

    function test_OutOfRangeWithdrawal() public {
        _verifyCurator();
        vm.startPrank(alice);
        token0.approve(address(vault), 20_000e18);
        token1.approve(address(vault), 20_000e18);
        uint256 shares = vault.deposit(10_000e18, 10_000e18, 1, block.timestamp + 1 hours);
        vm.stopPrank();

        vm.prank(curator);
        strategy.initialize(-60, 60, 3e24);

        SwapHelper swapper = new SwapHelper(manager);
        token0.transfer(address(swapper), 5_000e18);
        swapper.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: 2_000e18, sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-600)
            })
        );

        vm.prank(alice);
        (uint256 a0, uint256 a1,) = vault.withdraw(shares, 0, 0, block.timestamp + 1 hours);
        assertGt(a0 + a1, 0);
        assertFalse(vault.hasPosition());
    }

    function test_PerformanceFee_LossPaysZero() public {
        PoolId id = PoolIdLibrary.toId(key);

        vm.prank(address(vault));
        assertEq(hook.authorizeFee(id, 0.9e18, 1e18, 1000), 0);

        vm.prank(address(vault));
        assertEq(hook.authorizeFee(id, 1.1e18, 1e18, 1000), 1000);

        vm.prank(address(vault));
        assertEq(hook.authorizeFee(id, 1.1e18, 1e18, 1000), 0);
    }

    event DynamicFeeSet(bytes32 indexed id, uint24 fee);
}
