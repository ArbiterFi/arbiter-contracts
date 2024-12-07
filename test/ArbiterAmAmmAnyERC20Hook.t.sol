// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {RewardTracker} from "../src/RewardTracker.sol";
import {PoolExtension} from "../src/libraries/PoolExtension.sol";
import {PositionExtension} from "../src/libraries/PositionExtension.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {PosmTestSetup} from "v4-periphery/test/shared/PosmTestSetup.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ArbiterAmAmmAnyERC20Hook} from "../src/ArbiterAmAmmAnyERC20Hook.sol";
import {PositionConfig} from "v4-periphery/test/shared/PositionConfig.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

contract ArbiterAmAmmAnyERC20HookTest is Test, PosmTestSetup {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    MockERC20 token0;
    MockERC20 token1;
    Currency rentCurrency;

    IPoolManager poolManager;
    IPositionManager positionManager;
    PoolId poolId;

    ArbiterAmAmmAnyERC20Hook arbiterHook;

    address user1 = address(0x1111111111111111111111111111111111111111);
    address user2 = address(0x2222222222222222222222222222222222222222);

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployAndMint2Currencies();

        MockERC20 rentToken = new MockERC20("TEST", "TEST", 18);
        rentToken.mint(address(this), 2 ** 255);
        rentCurrency = Currency.wrap(address(rentToken));

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));
        deployAndApprovePosm(manager);
        positionManager = lpm;

        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
                    Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                    Hooks.AFTER_SWAP_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(manager)),
            IPositionManager(address(lpm)),
            Currency.unwrap(rentCurrency),
            address(this)
        ); // Add all the necessary constructor arguments from the hook
        deployCodeTo("ArbiterAmAmmAnyERC20Hook.sol", constructorArgs, flags);

        arbiterHook = ArbiterAmAmmAnyERC20Hook(flags);

        // Create the poolKey
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            hooks: IHooks(arbiterHook),
            tickSpacing: 60
        });
        poolId = key.toId();

        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        poolManager = manager;
    }

    function addLiquidity(
        PoolKey memory poolKey,
        uint256 amount0Max,
        uint256 amount1Max,
        int24 tickLower,
        int24 tickUpper,
        address recipient
    ) internal {
        token0.approve(address(positionManager), amount0Max);
        token1.approve(address(positionManager), amount1Max);

        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );

        PositionConfig memory config = PositionConfig({poolKey: poolKey, tickLower: tickLower, tickUpper: tickUpper});
        mint(config, liquidity, recipient, Constants.ZERO_BYTES);
    }

    function test_ArbiterAmAmmAnyERC20HookTest_RewardsPerLiquidityIsZeroAfterInitialize() public view {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 rewardsPerLiquidityInsideX128 = arbiterHook.getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertEq(rewardsPerLiquidityInsideX128, 0, "Rewards per liquidity inside should be zero after initialize");
    }

    function test_ArbiterAmAmmAnyERC20HookTest_IncreasesWhenInRange() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId = positionManager.nextTokenId();
        addLiquidity(key, 10 ether, 10 ether, tickLower, tickUpper, address(this));
        positionManager.subscribe(tokenId, address(arbiterHook), ZERO_BYTES);

        IERC20(Currency.unwrap(rentCurrency)).approve(address(arbiterHook), 1 ether);
        arbiterHook.deposit(Currency.unwrap(rentCurrency), 1 ether);
        arbiterHook.donateRewards(key, 1 ether);

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);

        swap(key, true, -int128(amountIn), ZERO_BYTES);

        uint256 rewardsPerLiquidityInsideX128 = arbiterHook.getRewardsPerLiquidityInsideX128(key, tickLower, tickUpper);

        assertGt(rewardsPerLiquidityInsideX128, 0, "Rewards per liquidity inside should have increased");
    }

    function test_ArbiterAmAmmAnyERC20HookTest_DoesNotIncreaseWhenOutsideRange() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId = positionManager.nextTokenId();
        addLiquidity(key, 10 ether, 10 ether, tickLower, tickUpper, address(this));
        positionManager.subscribe(tokenId, address(arbiterHook), ZERO_BYTES);

        IERC20(Currency.unwrap(rentCurrency)).approve(address(arbiterHook), 1 ether);
        arbiterHook.deposit(Currency.unwrap(rentCurrency), 1 ether);
        arbiterHook.donateRewards(key, 1 ether);

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), 1 ether);

        bool zeroForOne = false;
        swap(key, zeroForOne, -int128(amountIn), ZERO_BYTES);

        uint256 rewardsPerLiquidityInsideX128Before = arbiterHook.getRewardsPerLiquidityInsideX128(
            key,
            tickLower,
            tickUpper
        );

        (, int24 tick, , ) = poolManager.getSlot0(key.toId());

        assertEq(tick, 5, "Tick should be 5");
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), 1 ether);

        swap(key, false, -int128(amountIn), ZERO_BYTES);

        (, int24 tick2, , ) = poolManager.getSlot0(key.toId());

        assertGt(tick2, 5, "Tick should be greater than 5");

        uint256 rewardsPerLiquidityInsideX128After = arbiterHook.getRewardsPerLiquidityInsideX128(
            key,
            tickLower,
            tickUpper
        );

        assertEq(
            rewardsPerLiquidityInsideX128Before,
            rewardsPerLiquidityInsideX128After,
            "Rewards per liquidity inside should not have increased - going right"
        );
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), 1 ether);

        swap(key, false, -int128(amountIn), ZERO_BYTES);

        (, int24 tick3, , ) = poolManager.getSlot0(key.toId());

        assertGt(tick3, tick2, "Tick should be greater than previous tick");

        uint256 rewardsPerLiquidityInsideX128After2 = arbiterHook.getRewardsPerLiquidityInsideX128(
            key,
            tickLower,
            tickUpper
        );

        assertEq(
            rewardsPerLiquidityInsideX128After,
            rewardsPerLiquidityInsideX128After2,
            "Rewards per liquidity inside should not have increased - going right 2"
        );

        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 1 ether);

        swap(key, true, -int128(amountIn), ZERO_BYTES);

        (, int24 tick4, , ) = poolManager.getSlot0(key.toId());

        assertLt(tick4, tick3, "Tick should be lesser than previous tick (going left this time)");

        assertGt(tick4, tick, "Tick should be greater than initial tick");

        uint256 rewardsPerLiquidityInsideX128After3 = arbiterHook.getRewardsPerLiquidityInsideX128(
            key,
            tickLower,
            tickUpper
        );

        assertEq(
            rewardsPerLiquidityInsideX128After2,
            rewardsPerLiquidityInsideX128After3,
            "Rewards per liquidity inside should not have increased - going left but still outside"
        );
    }

    function test_ArbiterAmAmmAnyERC20HookTest_RewardsCumulativeIsZeroAfterInitialize() public view {
        uint256 rewardsPerLiquidityCumulativeX128 = arbiterHook.getRewardsPerLiquidityCumulativeX128(key);

        assertEq(
            rewardsPerLiquidityCumulativeX128,
            0,
            "Rewards per liquidity cumulative should be zero after initialize"
        );
    }

    function test_ArbiterAmAmmAnyERC20HookTest_RewardsCumulativeGrowsAfterDonate() public {
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, address(this));
        positionManager.subscribe(tokenId, address(arbiterHook), ZERO_BYTES);

        uint256 rewardsPerLiquidityCumulativeX128Before = arbiterHook.getRewardsPerLiquidityCumulativeX128(key);

        IERC20(Currency.unwrap(rentCurrency)).approve(address(arbiterHook), 1 ether);
        arbiterHook.deposit(Currency.unwrap(rentCurrency), 1 ether);
        arbiterHook.donateRewards(key, 1 ether);

        uint256 rewardsPerLiquidityCumulativeX128After = arbiterHook.getRewardsPerLiquidityCumulativeX128(key);

        assertGt(
            rewardsPerLiquidityCumulativeX128After,
            rewardsPerLiquidityCumulativeX128Before,
            "Rewards per liquidity cumulative should have increased after donate"
        );

        IERC20(Currency.unwrap(rentCurrency)).approve(address(arbiterHook), 1 ether);
        arbiterHook.deposit(Currency.unwrap(rentCurrency), 1 ether);
        arbiterHook.donateRewards(key, 1 ether);

        uint256 rewardsPerLiquidityCumulativeX128After2 = arbiterHook.getRewardsPerLiquidityCumulativeX128(key);

        assertGt(
            rewardsPerLiquidityCumulativeX128After2,
            rewardsPerLiquidityCumulativeX128After,
            "Rewards per liquidity cumulative should have increased after donate 2"
        );
    }

    function test_ArbiterAmAmmAnyERC20HookTest_TwoPositionsInRange() public {
        currency0.transfer(user1, 1);
        currency1.transfer(user1, 1);
        currency0.transfer(user2, 1);
        currency1.transfer(user2, 1);

        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint256 tokenId1 = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, user1);
        vm.startPrank(user1);
        positionManager.subscribe(tokenId1, address(arbiterHook), ZERO_BYTES);
        vm.stopPrank();

        uint256 tokenId2 = positionManager.nextTokenId();
        addLiquidity(key, 1, 1, tickLower, tickUpper, user2);
        vm.startPrank(user2);
        positionManager.subscribe(tokenId2, address(arbiterHook), ZERO_BYTES);
        vm.stopPrank();

        IERC20(Currency.unwrap(rentCurrency)).approve(address(arbiterHook), 1 ether);
        arbiterHook.deposit(Currency.unwrap(rentCurrency), 1 ether);
        arbiterHook.donateRewards(key, 1 ether);

        vm.startPrank(user1);
        positionManager.unsubscribe(tokenId1);
        vm.stopPrank();

        vm.startPrank(user2);
        positionManager.unsubscribe(tokenId2);
        vm.stopPrank();

        vm.prank(user1);
        uint256 rewards1 = arbiterHook.collectRewards(user1);

        vm.prank(user2);
        uint256 rewards2 = arbiterHook.collectRewards(user2);

        assertEq(rewards1, rewards2, "Rewards accumulated for both positions should be the same");

        assertApproxEqRel(rewards1, 0.5 ether, 1e17, "Rewards should be split equally between the two positions");
        assertApproxEqRel(rewards2, 0.5 ether, 1e17, "Rewards should be split equally between the two positions");
    }
}
