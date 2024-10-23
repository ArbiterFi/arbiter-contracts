// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "lib/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "lib/v4-core/src/test/PoolSwapTest.sol";
import {ArbiterAmAmmSimpleHook} from "../src/ArbiterAmAmmSimpleHook.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";

import {LiquidityAmounts} from "lib/v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import {TestERC20} from "lib/v4-core/src/test/TestERC20.sol";
import {LPFeeLibrary} from "lib/v4-core/src/libraries/LPFeeLibrary.sol";

contract ArbiterAmAmmSimpleHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ArbiterAmAmmSimpleHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
                    Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager); // Add all the necessary constructor arguments from the hook
        deployCodeTo("ArbiterAmAmmSimpleHook.sol", constructorArgs, flags);
        hook = ArbiterAmAmmSimpleHook(flags);
    }

    function testInitializeArgsPass(bytes memory initArgs) public {
        vm.assume(initArgs.length == 1);
        _setUpPool(initArgs, true);
        (, , , bool zeroForOne) = hook.poolHookStates(poolId);
        assert(zeroForOne == (initArgs[0] > 0));
    }

    function testInitializeArgsFail(bytes memory initArgs) public {
        vm.assume(initArgs.length != 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(hook),
                abi.encodeWithSelector(ArbiterAmAmmSimpleHook.InitData.selector)
            )
        );
        _setUpPool(initArgs, true);
    }

    function testInitializeDynamicFeeFail(bytes memory initArgs) public {
        vm.assume(initArgs.length == 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.Wrap__FailedHookCall.selector,
                address(hook),
                abi.encodeWithSelector(ArbiterAmAmmSimpleHook.NotDynamicFee.selector)
            )
        );
        _setUpPool(initArgs, false);
    }

    function testProvideLiquididtyWithoutWinner(address user) public {
        bytes memory initArgs = abi.encodePacked(uint8(0));
        _setUpPool(initArgs, true);
        _provideLiquidity(user, -1, 1);
    }

    function testSwapWithoutWinner(uint128 amount) public {}

    function _setUpPool(bytes memory initArgs, bool dynamicFee) internal {
        // Create the pool
        (key, poolId) = initPool(
            currency0,
            currency1,
            hook,
            dynamicFee ? LPFeeLibrary.DYNAMIC_FEE_FLAG : 200,
            SQRT_PRICE_1_1,
            initArgs
        );
    }

    // function _setUpUser(address user) internal {
    //     // Mint tokens for user

    //     // Approve hook to spend user's tokens
    //     vm.startPrank(user);

    //     vm.stopPrank();
    // }

    function _provideLiquidity(address user, int8 lowerStep, int8 upperStep) internal {
        vm.startPrank(user);
        approvePosm();
        tickLower = -60;
        // TickMath.minUsableTick(key.tickSpacing); //int24(lowerStep) * key.tickSpacing;
        tickUpper = TickMath.maxUsableTick(key.tickSpacing); //int24(upperStep) * key.tickSpacing;

        TestERC20(Currency.unwrap(currency0)).mint(address(user), type(uint128).max);
        TestERC20(Currency.unwrap(currency1)).mint(address(user), type(uint128).max);

        uint128 liquidityAmount = 1e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId, ) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(user),
            block.timestamp,
            ZERO_BYTES
        );
        vm.stopPrank();
    }

    // function testArbiterAmAmmSimpleHook() public {}

    // function testLiquidityHooks() public {}
}
