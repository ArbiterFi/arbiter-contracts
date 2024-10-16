// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.24;

// import "forge-std/Test.sol";
// import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
// import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";
// import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";
// import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
// import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
// import {BalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
// import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
// import {CurrencyLibrary, Currency} from "lib/v4-core/src/types/Currency.sol";
// import {PoolSwapTest} from "lib/v4-core/src/test/PoolSwapTest.sol";
// import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
// import {Slot0Library, Slot0} from "lib/v4-core/src/types/Slot0.sol";

// import {LiquidityAmounts} from "lib/v4-core/test/utils/LiquidityAmounts.sol";
// import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
// import {EasyPosm} from "./utils/EasyPosm.sol";
// import {Fixtures} from "./utils/Fixtures.sol";

// import {Tracker} from "../src/Tracker.sol";
// import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

// contract DepositedLiquidityTrackerTest is Test, Fixtures {
//     using EasyPosm for IPositionManager;
//     using PoolIdLibrary for PoolKey;
//     using Slot0Library for Slot0;
//     using CurrencyLibrary for Currency;
//     using StateLibrary for IPoolManager;

//     Tracker hook;
//     PoolId poolId;

//     uint256 tokenId;
//     int24 tickLower;
//     int24 tickUpper;

//     function setUp() public {
//         // creates the pool manager, utility routers, and test tokens
//         deployFreshManagerAndRouters();
//         deployMintAndApprove2Currencies();

//         deployAndApprovePosm(manager);

//         // Deploy the hook to an address with the correct flags
//         address flags = address(
//             uint160(
//                 Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
//             ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
//         );
//         bytes memory constructorArgs = abi.encode(manager, posm); //Add all the necessary constructor arguments from the hook
//         deployCodeTo("Tracker.sol:Tracker", constructorArgs, flags);
//         hook = Tracker(flags);

//         // Create the pool
//         key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
//         poolId = key.toId();
//         manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

//         // Provide full-range liquidity to the pool
//         tickLower = TickMath.minUsableTick(key.tickSpacing);
//         tickUpper = TickMath.maxUsableTick(key.tickSpacing);

//         uint128 liquidityAmount = 100e18;

//         (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
//             SQRT_PRICE_1_1,
//             TickMath.getSqrtPriceAtTick(tickLower),
//             TickMath.getSqrtPriceAtTick(tickUpper),
//             liquidityAmount
//         );

//         (tokenId,) = posm.mint(
//             key,
//             tickLower,
//             tickUpper,
//             liquidityAmount,
//             amount0Expected + 1,
//             amount1Expected + 1,
//             address(this),
//             block.timestamp,
//             ZERO_BYTES
//         );
//     }

//     function testInitialization() public view {
//         // positions were created in setup()
//         (,int24 tick,,) = manager.getSlot0(poolId);
//         assertEq(hook.activeTick(poolId),tick);
//     }

//     function testSafeTransferOwner() public {
//         IERC721 posm = IERC721(address(posm));
//         posm.safeTransferFrom(address(this), address(hook), 1);
//         assertEq(posm.ownerOf(1), address(hook));
//         assertEq(hook.deposits(1), address(this));
//     }

//     function testIncreaseLiquidityOnSafeTransfer() public {
//         IERC721 posm = IERC721(address(posm));
//         posm.safeTransferFrom(address(this), address(hook), 1);
//         assertEq(hook.activeLiquidty(poolId), 100e18);
//     }

//     // function testSafeTransferLiquidity() public {
//     //     posm.safeTransferFrom(address(this), address(hook), tokenId);
//     //     assertEq(hook.activeLiquidity(poolId), 100e18);
//     // }
// }
