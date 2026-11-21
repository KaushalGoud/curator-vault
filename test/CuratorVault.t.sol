// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {CREATE2Deployer} from "../src/mocks/CREATE2Deployer.sol";
import {CuratorVaultHook} from "../src/CuratorVaultHook.sol";
import {CuratorVault} from "../src/CuratorVault.sol";
import {SimpleRangeStrategy} from "../src/SimpleRangeStrategy.sol";
import {SwapHelper} from "../src/mocks/SwapHelper.sol";
import {CuratorRegistry} from "../src/CuratorRegistry.sol";

contract CuratorVaultTest is Test {
    PoolManager manager;
    CuratorVaultHook hook;
    CuratorVault vault;
    SimpleRangeStrategy strategy;
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
        registry = new CuratorRegistry(IERC20(address(token0)), address(this), 100e18, 40, 50);

        vm.startPrank(curator);
        vault.setStrategy(address(strategy));
        vm.stopPrank();

        hook.setVault(address(vault));
        hook.setStrategy(address(strategy));
        hook.setRegistry(address(registry));
        hook.setMaxPerformanceFeeBps(1000);
        registry.setReporter(address(hook));
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
        _stake(address(strategy), 1_000_000e18);
        registry.approve(address(strategy));
        registry.registerVault(address(strategy), address(vault));
    }

    function _depositAlice(uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(alice);
        token0.approve(address(vault), amount);
        token1.approve(address(vault), amount);
        shares = vault.deposit(amount, amount, 1, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_HookPermissions() public view {
        assertTrue(uint160(address(hook)) & HOOK_FLAGS == HOOK_FLAGS, "hook flags");
    }

    function test_SetUpWiring() public view {
        assertEq(address(vault.hook()), address(hook));
        assertEq(address(strategy.vault()), address(vault));
        assertEq(vault.curator(), curator);
        assertEq(registry.reporter(), address(hook));
        assertFalse(registry.isApproved(address(strategy)));
    }

    function test_RegistryApprovalAndStartingReputation() public {
        assertFalse(registry.isApproved(address(strategy)));
        _verifyCurator();
        assertTrue(registry.isApproved(address(strategy)));
        assertEq(registry.reputation(address(strategy)), 50);
        assertEq(registry.aumCap(address(strategy)), 2_500_000e18);
    }

    function test_DepositMintsShares() public {
        _verifyCurator();
        uint256 shares = _depositAlice(10_000e18);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertGt(vault.navPerShare(), 0);
    }

    function test_DynamicFeeIncreasesWithDeviation() public view {
        uint24 fee = hook.computeFee(TickMath.getSqrtPriceAtTick(100), TickMath.getSqrtPriceAtTick(0));
        assertGt(fee, hook.baseFee());
        assertLe(fee, hook.maxFee());
    }

    function test_Gating_UnverifiedStrategyCannotAddLiquidity() public {
        _verifyCurator();
        _depositAlice(10_000e18);
        registry.revoke(address(strategy));

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
        uint256 shares = _depositAlice(10_000e18);
        vm.prank(curator);
        strategy.initialize(-60, 60, 3e24);
        assertTrue(vault.hasPosition());
        assertGt(vault.liquidity(), 0);
        assertGt(vault.navPerShare(), 0);

        vm.prank(alice);
        (uint256 a0, uint256 a1, uint256 perfFee) = vault.withdraw(shares, 0, 0, block.timestamp + 1 hours);
        assertGt(a0, 0);
        assertGt(a1, 0);
        assertEq(perfFee, 0);
        assertFalse(vault.hasPosition());
    }

    function test_DynamicFeeAppliedOnSwap() public {
        _verifyCurator();
        _depositAlice(10_000e18);

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
        _depositAlice(10_000e18);
        vm.prank(curator);
        strategy.initialize(-60, 60, 3e24);
        vm.warp(block.timestamp + 60);
        vm.prank(curator);
        vm.expectRevert(SimpleRangeStrategy.CooldownActive.selector);
        strategy.rebalance(-60, 60, 3e24);
    }

    function test_PerformanceFee_NoFeeBelowHWM() public {
        _verifyCurator();
        uint256 shares = _depositAlice(10_000e18);
        assertEq(vault.highWaterMark(), 1e18);

        vm.prank(alice);
        (,, uint256 perfFee) = vault.withdraw(shares / 2, 0, 0, block.timestamp + 1 hours);
        assertEq(perfFee, 0);
    }

    function test_Registry_StakeRequired() public {
        vm.expectRevert(CuratorRegistry.StakeTooLow.selector);
        registry.approve(address(strategy));
        assertFalse(registry.isApproved(address(strategy)));
    }

    function test_Registry_ApproveAfterStake() public {
        _stake(address(strategy), 200e18);
        assertFalse(registry.isApproved(address(strategy)));
        registry.approve(address(strategy));
        assertTrue(registry.isApproved(address(strategy)));
        assertEq(registry.stakeOf(address(strategy)), 200e18);
    }

    function test_Registry_StakeForCurator() public {
        token0.approve(address(registry), 200e18);
        registry.stakeFor(address(strategy), 200e18);
        registry.approve(address(strategy));
        assertTrue(registry.isApproved(address(strategy)));
    }

    function test_Registry_RevokedCuratorBlocked() public {
        _verifyCurator();
        _depositAlice(10_000e18);
        registry.revoke(address(strategy));
        assertFalse(registry.isApproved(address(strategy)));

        vm.prank(curator);
        vm.expectRevert();
        strategy.initialize(-60, 60, 3e24);
    }

    function test_Registry_OnlyReporterCanRecordPerformance() public {
        _verifyCurator();
        vm.prank(outsider);
        vm.expectRevert(CuratorRegistry.Unauthorized.selector);
        registry.recordPerformance(address(strategy), address(vault), 400);
    }

    function test_Registry_OnlyRegisteredVaultCanReport() public {
        _verifyCurator();
        vm.prank(address(hook));
        vm.expectRevert(CuratorRegistry.VaultNotRegistered.selector);
        registry.recordPerformance(address(strategy), outsider, 400);
    }

    function test_Registry_PositivePerformanceRaisesCap() public {
        _verifyCurator();
        uint256 capBefore = registry.aumCap(address(strategy));
        vm.prank(address(hook));
        registry.recordPerformance(address(strategy), address(vault), 400);
        assertGt(registry.reputation(address(strategy)), 50);
        assertGt(registry.aumCap(address(strategy)), capBefore);
    }

    function test_Registry_NegativePerformanceRevokes() public {
        _verifyCurator();
        vm.prank(address(hook));
        registry.recordPerformance(address(strategy), address(vault), -1000);
        assertFalse(registry.isApproved(address(strategy)));
        assertEq(registry.aumCap(address(strategy)), 0);
    }

    function test_DepositRespectsAumCap() public {
        _stake(address(strategy), 100e18);
        registry.approve(address(strategy));
        registry.registerVault(address(strategy), address(vault));

        vm.startPrank(alice);
        token0.approve(address(vault), 300e18);
        token1.approve(address(vault), 300e18);
        vm.expectRevert(CuratorVault.AumCapExceeded.selector);
        vault.deposit(300e18, 300e18, 1, block.timestamp + 1 hours);
        vm.stopPrank();
    }

    function test_FeeClaimAndReputationAfterOutperformance() public {
        _verifyCurator();
        uint256 shares = _depositAlice(10_000e18);
        token0.transfer(address(vault), 1000e18);
        assertGt(vault.navPerShare(), vault.hodlPerShare());

        vm.prank(alice);
        (,, uint256 perfFee) = vault.withdraw(shares, 0, 0, block.timestamp + 1 hours);
        assertGt(perfFee, 0);
        assertGt(vault.claimableFees(curator), 0);
        assertGt(registry.reputation(address(strategy)), 50);

        uint256 before = token0.balanceOf(curator);
        vm.prank(curator);
        vault.claimPerformanceFees();
        assertEq(token0.balanceOf(curator), before + perfFee);
        assertEq(vault.claimableFees(curator), 0);
    }

    function test_ClaimFeesRequiresFees() public {
        vm.prank(curator);
        vm.expectRevert(CuratorVault.NoFees.selector);
        vault.claimPerformanceFees();
    }

    function testFuzz_ComputeFeeWithinBounds(uint160 ref, uint160 delta) public view {
        vm.assume(ref > 0);
        uint160 current = ref > type(uint160).max - delta ? type(uint160).max : ref + delta;
        assertGe(hook.computeFee(current, ref), hook.baseFee());
        assertLe(hook.computeFee(current, ref), hook.maxFee());
    }

    function testFuzz_DepositShareAccounting(uint256 amount) public {
        vm.assume(amount >= 1e18 && amount <= 1000e18);
        _verifyCurator();
        uint256 shares = _depositAlice(amount);
        assertEq(vault.balanceOf(alice), shares);
        assertGt(vault.navPerShare(), 0);
    }

    function test_Invariant_NavMatchesDeposits() public {
        _verifyCurator();
        _depositAlice(10_000e18);
        assertEq(vault.totalNav(), 20_000e18);
        assertEq(vault.hodlPerShare(), 1e18);
    }

    function test_OutOfRangeWithdrawal() public {
        _verifyCurator();
        uint256 shares = _depositAlice(10_000e18);
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
