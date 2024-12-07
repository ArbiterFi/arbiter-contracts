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

// import {HookEnabledSwapRouter} from "./utils/HookEnabledSwapRouter.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

// Interfaces for your hook
import {IArbiterFeeProvider} from "../src/interfaces/IArbiterFeeProvider.sol";
import {IArbiterAmAmmHarbergerLease} from "../src/interfaces/IArbiterAmAmmHarbergerLease.sol";
import {ArbiterAmAmmPoolCurrencyHook} from "../src/ArbiterAmAmmPoolCurrencyHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AuctionSlot0, AuctionSlot0Library} from "../src/types/AuctionSlot0.sol";
import {AuctionSlot1, AuctionSlot1Library} from "../src/types/AuctionSlot1.sol";

contract MockStrategy is IArbiterFeeProvider {
    uint24 public fee;

    constructor(uint24 _fee) {
        fee = _fee;
    }

    function getSwapFee(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external view returns (uint24) {
        return fee;
    }

    function setFee(uint24 _fee) external {
        fee = _fee;
    }
}

contract ArbiterAmAmmPoolCurrencyHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    // HookEnabledSwapRouter router;
    ArbiterAmAmmPoolCurrencyHook arbiterHook;

    MockERC20 token0;
    MockERC20 token1;

    PoolId id;
    IPoolManager poolManager;

    address user1 = address(0x1111);
    address user2 = address(0x2222);

    uint256 constant STARTING_BLOCK = 10_000_000;
    uint256 CURRENT_BLOCK_NUMBER = STARTING_BLOCK;

    uint24 constant DEFAULT_SWAP_FEE = 300;
    uint32 constant DEFAULT_MINIMUM_RENT_BLOCKS = 300;
    uint24 constant DEFAULT_WINNER_FEE_SHARE = 50_000; // 5%
    uint24 constant DEFAULT_POOL_SWAP_FEE = 50_000; // 5%

    function setUp() public {
        vm.roll(STARTING_BLOCK);
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployAndMint2Currencies();

        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // router = new HookEnabledSwapRouter(manager);

        // Deploy the Arbiter hook

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
            true, // RENT_IN_TOKEN_ZERO
            address(this)
        ); // Add all the necessary constructor arguments from the hook
        deployCodeTo("ArbiterAmAmmPoolCurrencyHook.sol", constructorArgs, flags);
        arbiterHook = ArbiterAmAmmPoolCurrencyHook(flags);

        // Create the poolKey with dynamic fee flag (requirement from the hook)
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            hooks: IHooks(arbiterHook),
            tickSpacing: 60
        });
        id = key.toId();

        // Initialize the pool at price 1:1
        manager.initialize(key, Constants.SQRT_PRICE_1_1);
        poolManager = manager;

        addLiquidity(key, 10 ether, 10 ether, -60, 60);
    }

    function addLiquidity(
        PoolKey memory poolKey,
        uint256 amount0Max,
        uint256 amount1Max,
        int24 tickLower,
        int24 tickUpper
    ) internal {
        token0.approve(address(modifyLiquidityNoChecks), amount0Max);
        token1.approve(address(modifyLiquidityNoChecks), amount1Max);

        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(key.toId());
        uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(liquidity),
            salt: 0
        });

        modifyLiquidityNoChecks.modifyLiquidity(poolKey, params, Constants.ZERO_BYTES);
    }

    function resetCurrentBlock() public {
        CURRENT_BLOCK_NUMBER = STARTING_BLOCK;
    }

    function moveBlockBy(uint256 interval) public {
        CURRENT_BLOCK_NUMBER += interval;
        vm.roll(CURRENT_BLOCK_NUMBER);
    }

    function transferToAndDepositAs(uint256 amount, address user) public {
        currency0.transfer(user, amount);
        vm.startPrank(user);
        IERC20(Currency.unwrap(currency0)).approve(address(arbiterHook), amount);
        arbiterHook.deposit(Currency.unwrap(currency0), amount);
        vm.stopPrank();
    }

    function test_ArbiterAmAmmPoolCurrencyHook_BiddingAndRentPayment() public {
        resetCurrentBlock();
        transferToAndDepositAs(10_000e18, user1);
        //offset blocks
        moveBlockBy(100);

        // User1 overbids
        vm.prank(user1);
        arbiterHook.overbid(
            key,
            10e18,
            uint32(STARTING_BLOCK + 100 + DEFAULT_MINIMUM_RENT_BLOCKS),
            address(0) // strategy (none)
        );
        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint128 startingRent = slot1.remainingRent();

        address winner = arbiterHook.winner(key);
        assertEq(winner, user1, "Winner should be user1 after overbidding");

        moveBlockBy(5);
        addLiquidity(key, 1, 1, -60, 60);

        slot1 = arbiterHook.poolSlot1(id);
        uint128 remainingRent = slot1.remainingRent();
        assertEq(startingRent - remainingRent, 5 * 10e18, "Remaining rent should be less than initial deposit");

        // add liquidity
        addLiquidity(key, 1, 1, -60, 60);
    }

    function test_ArbiterAmAmmPoolCurrencyHook_StrategyContractSetsFee() public {
        resetCurrentBlock();
        // Deploy a mock strategy that sets swap fee to DEFAULT_POOL_SWAP_FEE
        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);

        // User1 deposits and overbids with the strategy
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);

        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();

        uint256 prevBalance0 = key.currency0.balanceOf(address(this));

        uint128 amountIn = 1e18;
        moveBlockBy(1);

        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        uint256 postBalance0 = key.currency0.balanceOf(address(this));

        uint256 feeAmount = (amountIn * DEFAULT_POOL_SWAP_FEE) / 1e6;
        uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) / 1e6;

        assertEq(prevBalance0 - postBalance0, amountIn, "Amount in mismatch");

        assertEq(
            poolManager.protocolFeesAccrued(key.currency0),
            0,
            "Protocol fees accrued in currency0 should be zero"
        );
        assertEq(
            poolManager.protocolFeesAccrued(key.currency0),
            0,
            "Protocol fees accrued in currency0 should be zero"
        );

        uint256 strategyBalance = poolManager.balanceOf(address(strategy), key.currency1.toId());
        assertEq(strategyBalance, expectedFeeAmount, "Strategy balance does not match expected fee amount");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_StrategyFeeCappedAtMaxFee() public {
        resetCurrentBlock();
        // Deploy a mock strategy that sets swap fee to a value greater than DEFAULT_POOL_SWAP_FEE
        uint24 strategyFee = 1e6 + 1000; // Fee greater than DEFAULT_POOL_SWAP_FEE
        MockStrategy strategy = new MockStrategy(strategyFee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        moveBlockBy(1);
        vm.stopPrank();

        // Record initial balances
        uint256 prevBalance0 = key.currency0.balanceOf(address(this));

        // Perform a swap
        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        // Record final balances
        uint256 postBalance0 = key.currency0.balanceOf(address(this));

        uint256 feeAmount = (amountIn * 400) / 1e6; // capped at 1e6 (100%)
        uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) / 1e6;

        assertEq(prevBalance0 - postBalance0, amountIn, "Amount in mismatch");

        uint256 strategyBalance = poolManager.balanceOf(address(strategy), key.currency1.toId());
        assertEq(strategyBalance, expectedFeeAmount, "Strategy balance should match expected fee amount");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_DepositAndWithdraw() public {
        resetCurrentBlock();
        // User1 deposits currency0

        transferToAndDepositAs(100e18, user1);

        uint256 depositBalance = arbiterHook.depositOf(Currency.unwrap(currency0), user1);
        assertEq(depositBalance, 100e18, "Deposit amount does not match expected value");

        // User1 withdraws half
        vm.startPrank(user1);
        arbiterHook.withdraw(Currency.unwrap(currency0), 50e18);

        depositBalance = arbiterHook.depositOf(Currency.unwrap(currency0), user1);
        assertEq(depositBalance, 50e18, "Deposit balance should be 50e18 after withdrawing half");

        // withdraws the rest
        arbiterHook.withdraw(Currency.unwrap(currency0), 50e18);
        depositBalance = arbiterHook.depositOf(Currency.unwrap(currency0), user1);
        assertEq(depositBalance, 0, "Deposit balance should be zero after withdrawing all");

        vm.stopPrank();
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ChangeStrategy() public {
        resetCurrentBlock();
        // User1 overbids and becomes the winner
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(0));
        vm.stopPrank();

        // User1 changes strategy
        MockStrategy newStrategy = new MockStrategy(5000);
        vm.prank(user1);
        arbiterHook.changeStrategy(key, address(newStrategy));
        moveBlockBy(1);

        addLiquidity(key, 1, 1, -60, 60);

        address currentStrategy = arbiterHook.activeStrategy(key);
        assertEq(currentStrategy, address(newStrategy), "Active strategy should be updated to new strategy");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_RevertIfNotDynamicFee() public {
        resetCurrentBlock();
        // Creating a non-dynamic fee PoolKey
        PoolKey memory nonDynamicKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: DEFAULT_SWAP_FEE,
            hooks: IHooks(arbiterHook),
            tickSpacing: 60
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(arbiterHook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(IArbiterAmAmmHarbergerLease.NotDynamicFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(nonDynamicKey, Constants.SQRT_PRICE_1_1);
    }

    function test_ArbiterAmAmmPoolCurrencyHook_RentTooLow() public {
        resetCurrentBlock();
        // User1 deposits currency0
        transferToAndDepositAs(10_000e18, user1);

        vm.prank(user1);
        arbiterHook.overbid(key, 1e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(0));
        vm.expectRevert(IArbiterAmAmmHarbergerLease.RentTooLow.selector);
        arbiterHook.overbid(key, 1e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(0));
    }

    function test_ArbiterAmAmmPoolCurrencyHook_NotWinnerCannotChangeStrategy() public {
        resetCurrentBlock();
        // User1 overbids and becomes the winner
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(0));
        vm.stopPrank();

        // User2 tries to change strategy
        vm.prank(user2);
        vm.expectRevert(IArbiterAmAmmHarbergerLease.CallerNotWinner.selector);
        arbiterHook.changeStrategy(key, address(0));
    }

    function test_ArbiterAmAmmPoolCurrencyHook_DefaultFeeWhenNoOneHasWon() public {
        resetCurrentBlock();
        // Ensure there is no winner and no strategy set
        address currentWinner = arbiterHook.winner(key);
        address currentStrategy = arbiterHook.activeStrategy(key);
        assertEq(currentWinner, address(0), "Initial winner should be address(0)");
        assertEq(currentStrategy, address(0), "Initial strategy should be address(0)");

        uint128 amountIn = 1e18;
        currency0.transfer(user1, 1000e18);

        // Record initial balances
        uint256 prevBalance0 = key.currency0.balanceOf(address(user1));
        uint256 prevBalance1 = key.currency1.balanceOf(address(user1));

        assertEq(prevBalance0, 1000e18, "Initial balance0 mismatch");
        assertEq(prevBalance1, 0, "Initial balance1 mismatch");

        // Perform a swap as user1
        vm.startPrank(user1);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);
        vm.stopPrank();

        // Record final balances
        uint256 postBalance0 = key.currency0.balanceOf(address(user1));

        assertEq(prevBalance0 - postBalance0, amountIn, "Amount in mismatch");

        uint256 strategyBalance = poolManager.balanceOf(address(currentStrategy), key.currency1.toId());
        assertEq(strategyBalance, 0, "Strategy balance should be zero when no one has won");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_DefaultFeeAfterAuctionWinExpired() public {
        resetCurrentBlock();
        // Deploy a mock strategy that sets swap fee to DEFAULT_POOL_SWAP_FEE
        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);

        // User1 deposits and overbids with the strategy
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);

        // Set rent to expire in DEFAULT_MINIMUM_RENT_BLOCKS
        uint32 rentEndBlock = uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS);
        arbiterHook.overbid(key, 10e18, rentEndBlock, address(strategy));
        vm.stopPrank();
        moveBlockBy(1);

        uint128 amountIn = 1e18;
        // Perform a swap before rent expires
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        moveBlockBy(DEFAULT_MINIMUM_RENT_BLOCKS - 1);
        uint32 currentBlock = uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS);
        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint64 rentEndBlockFromContract = slot1.rentEndBlock();
        assertEq(currentBlock, rentEndBlockFromContract, "currentBlock vs rent end block mismatch");

        moveBlockBy(1);

        // Perform another swap after rent has technically expired
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        uint256 strategyBalance = poolManager.balanceOf(address(strategy), key.currency1.toId());
        assertGt(strategyBalance, 0, "Strategy balance should be greater than zero after rent expiry");

        moveBlockBy(1);

        // Trigger _payRent by adding liquidity
        addLiquidity(key, 1, 1, -60, 60);

        address currentWinner = arbiterHook.winner(key);
        assertEq(currentWinner, address(0), "Winner should be reset to address(0) after rent expiry");

        uint256 strategyBalancePostExpiry = poolManager.balanceOf(address(strategy), key.currency1.toId());
        assertEq(strategyBalancePostExpiry, strategyBalance, "Strategy balance not increase after rent expiry");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_DepositOf() public {
        resetCurrentBlock();
        uint256 initialDeposit = arbiterHook.depositOf(Currency.unwrap(currency0), user1);
        assertEq(initialDeposit, 0, "Initial deposit should be zero");

        transferToAndDepositAs(10_000e18, user1);

        uint256 postDeposit = arbiterHook.depositOf(Currency.unwrap(currency0), user1);
        assertEq(postDeposit, 10_000e18, "Deposit amount does not match expected value");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_BiddingCurrency() public {
        resetCurrentBlock();
        address expectedCurrency = Currency.unwrap(currency0);
        address actualCurrency = arbiterHook.biddingCurrency(key);
        assertEq(actualCurrency, expectedCurrency, "Bidding currency does not match expected value");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ActiveStrategySameBlockAsOverbid() public {
        resetCurrentBlock();
        address initialStrategy = arbiterHook.activeStrategy(key);
        assertEq(initialStrategy, address(0), "Initial active strategy should be address(0)");

        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);

        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();

        // Trigger _payRent by adding liquidity
        addLiquidity(key, 1, 1, -60, 60);

        address activeStrategy = arbiterHook.activeStrategy(key);
        assertEq(address(0), activeStrategy, "Active strategy was updated unexpectedly");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ActiveStrategyDifferentBlock() public {
        resetCurrentBlock();
        address initialStrategy = arbiterHook.activeStrategy(key);
        assertEq(initialStrategy, address(0), "Initial active strategy should be address(0)");

        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);

        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();

        moveBlockBy(1);

        // Trigger _payRent
        addLiquidity(key, 1, 1, -60, 60);

        address updatedStrategy = arbiterHook.activeStrategy(key);
        assertEq(updatedStrategy, address(strategy), "Active strategy was not updated correctly");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_WinnerStrategy() public {
        resetCurrentBlock();
        address initialWinnerStrategy = arbiterHook.winnerStrategy(key);
        assertEq(initialWinnerStrategy, address(0), "Initial winner strategy should be address(0)");

        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();

        address currentWinnerStrategy = arbiterHook.winnerStrategy(key);
        assertEq(currentWinnerStrategy, address(strategy), "Winner strategy was not set correctly");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_Winner() public {
        resetCurrentBlock();
        address initialWinner = arbiterHook.winner(key);
        assertEq(initialWinner, address(0), "Initial winner should be address(0)");

        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);

        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();

        address currentWinner = arbiterHook.winner(key);
        assertEq(currentWinner, user1, "Winner was not set correctly");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_RentPerBlock() public {
        resetCurrentBlock();
        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint96 initialRentPerBlock = slot1.rentPerBlock();
        assertEq(initialRentPerBlock, 0, "Initial rentPerBlock should be zero");

        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);
        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);

        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();

        slot1 = arbiterHook.poolSlot1(id);
        uint96 rentPerBlockBeforePayment = slot1.rentPerBlock();
        assertEq(rentPerBlockBeforePayment, 10e18, "rentPerBlock should not update until rent is paid");

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        slot1 = arbiterHook.poolSlot1(id);
        uint96 updatedRentPerBlock = slot1.rentPerBlock();
        assertEq(updatedRentPerBlock, 10e18, "rentPerBlock was not updated correctly");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_RentEndBlock() public {
        resetCurrentBlock();
        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint64 initialRentEndBlock = slot1.rentEndBlock();
        assertEq(
            initialRentEndBlock,
            STARTING_BLOCK,
            "initial rentEndBlock should be equal to the latest add liquidity's block when no rent is paid"
        );

        uint32 desiredRentEndBlock = uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS);
        MockStrategy strategy = new MockStrategy(DEFAULT_POOL_SWAP_FEE);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, desiredRentEndBlock, address(strategy));
        vm.stopPrank();

        slot1 = arbiterHook.poolSlot1(id);
        uint64 currentRentEndBlock = slot1.rentEndBlock();
        assertEq(currentRentEndBlock, desiredRentEndBlock, "rentEndBlock was not set correctly");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ExactOutZeroForOne() public {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();
        moveBlockBy(1);

        uint128 amountOut = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 2e18); // enough to cover maximum
        // exactOutputSingle -> swap exact out: amountSpecified > 0
        swap(key, true, int128(amountOut), ZERO_BYTES);
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ExactOutOneForZero() public {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();
        moveBlockBy(1);

        uint128 amountOut = 1e18;
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), 2e18); // approve input token as needed
        // zeroForOne = false, exact out: pass positive
        swap(key, false, int128(amountOut), ZERO_BYTES);
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ExactInZeroForOne() public {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();

        uint128 amountIn = 1e18;
        moveBlockBy(1);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        // exact input: negative amountSpecified
        swap(key, true, -int128(amountIn), ZERO_BYTES);
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ExactInOneForZero() public {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();
        moveBlockBy(1);

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), amountIn);
        // exact input: negative amountSpecified
        swap(key, false, -int128(amountIn), ZERO_BYTES);
    }

    function test_ArbiterAmAmmPoolCurrencyHook_WinnerCanChangeFeeAndSwapReflects() public {
        resetCurrentBlock();
        uint24 initialFee = 1000;
        uint24 updatedFee = 2000;
        MockStrategy strategy = new MockStrategy(initialFee);

        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();
        moveBlockBy(1);

        strategy.setFee(updatedFee);

        // Perform a swap
        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);

        swap(key, true, -int128(amountIn), ZERO_BYTES);

        uint256 feeAmount = (amountIn * updatedFee) / 1e6;
        uint256 expectedFeeAmount = (feeAmount * DEFAULT_WINNER_FEE_SHARE) / 1e6;

        uint256 strategyBalance = poolManager.balanceOf(address(strategy), key.currency1.toId());
        assertEq(strategyBalance, expectedFeeAmount, "Strategy balance should reflect updated fee");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_RemainingRentDecreases() public {
        resetCurrentBlock();
        transferToAndDepositAs(10_000e18, user1);

        // User1 overbids
        vm.prank(user1);
        moveBlockBy(1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + 1 + DEFAULT_MINIMUM_RENT_BLOCKS), address(0));

        moveBlockBy(10);
        // 1st swap
        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);

        uint128 expectedDonate = 10e18 * 10;
        vm.expectEmit(true, true, true, false);
        emit IPoolManager.Donate(key.toId(), address(arbiterHook), expectedDonate, 0);

        swap(key, true, -int128(amountIn), ZERO_BYTES);

        // Check remaining rent
        AuctionSlot1 slot1 = arbiterHook.poolSlot1(id);
        uint128 remainingRent = slot1.remainingRent();
        assertLt(remainingRent, 10_000e18, "Remaining rent should be less than initial deposit");

        // 2nd swap
        moveBlockBy(10);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        slot1 = arbiterHook.poolSlot1(id);
        uint128 remainingRent2 = slot1.remainingRent();
        assertEq(remainingRent2, remainingRent - expectedDonate, "Remaining rent should decrease by expectedDonate");

        // 3rd swap
        moveBlockBy(10);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        slot1 = arbiterHook.poolSlot1(id);
        uint128 remainingRent3 = slot1.remainingRent();
        assertEq(
            remainingRent3,
            remainingRent2 - expectedDonate,
            "Remaining rent should decrease by another expectedDonate"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_MultipleSwapsSameBlock() public {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();

        uint128 amountIn = 1e18;
        moveBlockBy(1);
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn * 2);

        // Perform two swaps in the same block
        swap(key, true, -int128(amountIn), ZERO_BYTES);
        swap(key, true, -int128(amountIn), ZERO_BYTES);
    }

    function test_ArbiterAmAmmPoolCurrencyHook_OverbidAndSwapSameBlock() public {
        resetCurrentBlock();
        uint24 fee = 1000;
        MockStrategy strategy = new MockStrategy(fee);

        transferToAndDepositAs(10_000e18, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS), address(strategy));
        vm.stopPrank();

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        // exact input: negative amountSpecified
        swap(key, true, -int128(amountIn), ZERO_BYTES);
    }

    function test_ArbiterAmAmmPoolCurrencyHook_OverbidMultipleBids() public {
        resetCurrentBlock();
        uint24 feeUser1 = 1000;
        uint24 feeUser2 = 500;
        MockStrategy strategyUser1 = new MockStrategy(feeUser1);
        MockStrategy strategyUser2 = new MockStrategy(feeUser2);

        uint32 rentEndBlock = uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS);

        transferToAndDepositAs(10_000e18, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(key, 10e18, rentEndBlock, address(strategyUser1));
        vm.stopPrank();
        moveBlockBy(1);

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        uint256 feeAmountUser1 = (amountIn * feeUser1) / 1e6;
        uint256 expectedFeeAmountUser1 = (feeAmountUser1 * DEFAULT_WINNER_FEE_SHARE) / 1e6;

        uint256 strategyUser1Balance = poolManager.balanceOf(address(strategyUser1), key.currency1.toId());
        assertEq(
            strategyUser1Balance,
            expectedFeeAmountUser1,
            "Strategy user1 did not receive correct fees after first swap"
        );

        transferToAndDepositAs(20_000e18, user2);

        vm.startPrank(user2);
        arbiterHook.overbid(key, 11e18, rentEndBlock + 100, address(strategyUser2));
        vm.stopPrank();
        moveBlockBy(1);

        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        uint256 feeAmountUser2 = (amountIn * feeUser2) / 1e6;
        uint256 expectedFeeAmountUser2 = (feeAmountUser2 * DEFAULT_WINNER_FEE_SHARE) / 1e6;

        uint256 strategyUser2Balance = poolManager.balanceOf(address(strategyUser2), key.currency1.toId());
        assertEq(
            strategyUser2Balance,
            expectedFeeAmountUser2,
            "Strategy user2 did not receive correct fees after second swap"
        );

        uint256 strategyUser1BalanceAfter = poolManager.balanceOf(address(strategyUser1), key.currency1.toId());
        assertEq(
            strategyUser1BalanceAfter,
            strategyUser1Balance,
            "User1 strategy unexpectedly earned additional fees after losing the auction"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_AuctionFeeDepositRequirement() public {
        resetCurrentBlock();

        arbiterHook.setAuctionFee(key, 500);

        uint80 rentPerBlock = 10e18;
        AuctionSlot0 slot0 = arbiterHook.poolSlot0(id);
        uint24 hookAuctionFee = slot0.auctionFee();
        assertEq(hookAuctionFee, 500, "Auction fee should be 500");

        uint128 totalRent = rentPerBlock * DEFAULT_MINIMUM_RENT_BLOCKS;
        uint128 auctionFee = (totalRent * hookAuctionFee) / 1e6;

        uint32 rentEndBlock = uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS);

        transferToAndDepositAs(totalRent, user1);
        vm.prank(user1);
        vm.expectRevert(IArbiterAmAmmHarbergerLease.InsufficientDeposit.selector);
        arbiterHook.overbid(key, rentPerBlock, rentEndBlock, address(0));

        transferToAndDepositAs(auctionFee, user1);

        vm.prank(user1);
        arbiterHook.overbid(key, rentPerBlock, rentEndBlock, address(0));

        address winner = arbiterHook.winner(key);
        assertEq(winner, user1, "User1 should be the winner after depositing the full required amount");
    }

    function test_ArbiterAmAmmPoolCurrencyHook_TwoUsersOverbidSameBlock() public {
        resetCurrentBlock();
        uint24 feeUser1 = 1000;
        uint24 feeUser2 = 2000;
        MockStrategy strategyUser1 = new MockStrategy(feeUser1);
        MockStrategy strategyUser2 = new MockStrategy(feeUser2);

        uint32 rentEndBlock = uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS);

        uint80 user1Rent = 10e18;
        uint80 user1Deposit = user1Rent * DEFAULT_MINIMUM_RENT_BLOCKS;
        uint256 user1BalancePreDeposit = key.currency0.balanceOf(user1);

        transferToAndDepositAs(user1Deposit, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(key, user1Rent, rentEndBlock, address(strategyUser1));
        vm.stopPrank();

        uint80 user2Rent = 20e18;
        transferToAndDepositAs(user2Rent * DEFAULT_MINIMUM_RENT_BLOCKS, user2);
        vm.startPrank(user2);
        arbiterHook.overbid(key, user2Rent, rentEndBlock, address(strategyUser2));
        vm.stopPrank();

        address winner = arbiterHook.winner(key);
        assertEq(winner, user2, "User2 should be the winner after the higher overbid in the same block");

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        uint256 feeAmountUser2 = (amountIn * feeUser2) / 1e6;
        uint256 expectedFeeAmountUser2 = (feeAmountUser2 * DEFAULT_WINNER_FEE_SHARE) / 1e6;

        uint256 strategyUser2Balance = poolManager.balanceOf(address(strategyUser2), key.currency1.toId());
        assertEq(
            strategyUser2Balance,
            expectedFeeAmountUser2,
            "Strategy user2 did not receive the correct fees after winning"
        );

        uint256 user1DepositBefore = arbiterHook.depositOf(Currency.unwrap(currency0), user1);
        assertEq(user1DepositBefore, user1Deposit, "User1's deposit should still be intact");

        vm.startPrank(user1);
        arbiterHook.withdraw(Currency.unwrap(currency0), user1Deposit);
        vm.stopPrank();

        uint256 user1DepositAfter = arbiterHook.depositOf(Currency.unwrap(currency0), user1);
        assertEq(user1DepositAfter, 0, "User1 should be able to withdraw their full deposit after losing");

        uint256 user1BalancePostWithdraw = key.currency0.balanceOf(user1);
        assertEq(
            user1BalancePreDeposit,
            user1BalancePostWithdraw,
            "User1 should have their deposit returned to their wallet"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_TwoUsersOverbidSameBlockWithAuctionFee() public {
        resetCurrentBlock();

        arbiterHook.setAuctionFee(key, 500);
        AuctionSlot0 slot0 = arbiterHook.poolSlot0(id);
        uint24 hookAuctionFee = slot0.auctionFee();
        assertEq(hookAuctionFee, 500, "Auction fee should be 500");

        uint24 feeUser1 = 1000;
        uint24 feeUser2 = 2000;
        MockStrategy strategyUser1 = new MockStrategy(feeUser1);
        MockStrategy strategyUser2 = new MockStrategy(feeUser2);

        uint32 rentEndBlock = uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS);

        uint80 user1Rent = 10e18;
        uint128 user1TotalRent = user1Rent * DEFAULT_MINIMUM_RENT_BLOCKS;
        uint128 user1AuctionFee = (user1TotalRent * hookAuctionFee) / 1e6;
        uint128 user1Deposit = user1TotalRent + user1AuctionFee;

        uint256 user1BalancePreDeposit = key.currency0.balanceOf(user1);
        transferToAndDepositAs(user1Deposit, user1);
        vm.startPrank(user1);
        arbiterHook.overbid(key, user1Rent, rentEndBlock, address(strategyUser1));
        vm.stopPrank();

        uint80 user2Rent = 20e18;
        uint128 user2TotalRent = user2Rent * DEFAULT_MINIMUM_RENT_BLOCKS;
        uint128 user2AuctionFee = (user2TotalRent * hookAuctionFee) / 1e6;
        uint128 user2Deposit = user2TotalRent + user2AuctionFee;

        transferToAndDepositAs(user2Deposit, user2);
        vm.startPrank(user2);
        arbiterHook.overbid(key, user2Rent, rentEndBlock, address(strategyUser2));
        vm.stopPrank();

        address winner = arbiterHook.winner(key);
        assertEq(winner, user2, "User2 should be the winner after the higher overbid in the same block");

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        (uint128 initialRemainingRent, uint128 feeLocked, ) = arbiterHook.auctionFees(id);
        assertEq(feeLocked, user2AuctionFee, "Auction fee should be collected for user2");
        assertEq(initialRemainingRent, user2TotalRent, "Initial remaining rent should be equal to user2's total rent");

        uint256 feeAmountUser2 = (amountIn * feeUser2) / 1e6;
        uint256 expectedFeeAmountUser2 = (feeAmountUser2 * DEFAULT_WINNER_FEE_SHARE) / 1e6;

        uint256 strategyUser2Balance = poolManager.balanceOf(address(strategyUser2), key.currency1.toId());
        assertEq(
            strategyUser2Balance,
            expectedFeeAmountUser2,
            "Strategy user2 did not receive the correct fees after winning"
        );

        uint256 user1DepositBefore = arbiterHook.depositOf(Currency.unwrap(currency0), user1);
        assertEq(user1DepositBefore, user1Deposit, "User1's deposit should still be intact");

        vm.startPrank(user1);
        arbiterHook.withdraw(Currency.unwrap(currency0), user1Deposit);
        vm.stopPrank();

        uint256 user1DepositAfter = arbiterHook.depositOf(Currency.unwrap(currency0), user1);
        assertEq(user1DepositAfter, 0, "User1 should be able to withdraw their full deposit after losing");

        uint256 user1BalancePostWithdraw = key.currency0.balanceOf(user1);
        assertEq(
            user1BalancePreDeposit,
            user1BalancePostWithdraw,
            "User1 should have their deposit returned to their wallet"
        );
    }

    function test_ArbiterAmAmmPoolCurrencyHook_ComplexAuctionScenario() public {
        // Scenario described in comments is unchanged, just updating swaps and balance checks.

        resetCurrentBlock();

        // Set auction fee to 500 (0.05%)
        arbiterHook.setAuctionFee(key, 500);
        AuctionSlot0 slot0 = arbiterHook.poolSlot0(id);
        uint24 hookAuctionFee = slot0.auctionFee();
        assertEq(hookAuctionFee, 500, "Auction fee should be 500");

        // Define rents and strategies
        uint24 feeUser1 = 1000; // 0.1%
        uint24 feeUser2 = 2000; // 0.2%
        MockStrategy strategyUser1 = new MockStrategy(feeUser1);
        MockStrategy strategyUser2 = new MockStrategy(feeUser2);

        uint32 rentEndBlock = uint32(STARTING_BLOCK + DEFAULT_MINIMUM_RENT_BLOCKS);

        // User1 scenario
        uint80 user1RentPerBlock = 10e18;
        uint128 user1TotalRent = user1RentPerBlock * DEFAULT_MINIMUM_RENT_BLOCKS;
        uint128 user1AuctionFee = (user1TotalRent * hookAuctionFee) / 1e6;
        uint128 user1Deposit = user1TotalRent + user1AuctionFee;

        uint256 user1BalancePreDeposit = key.currency0.balanceOf(user1);
        transferToAndDepositAs(user1Deposit, user1);

        vm.startPrank(user1);
        arbiterHook.overbid(key, user1RentPerBlock, rentEndBlock, address(strategyUser1));
        vm.stopPrank();

        moveBlockBy(10);

        uint128 amountIn = 1e18;
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        uint128 remainingRentAfterSwapUser1 = arbiterHook.poolSlot1(id).remainingRent();
        assertEq(
            remainingRentAfterSwapUser1,
            user1TotalRent - 10 * user1RentPerBlock,
            "Remaining rent should be reduced by 10 blocks of rent"
        );

        uint256 feeAmountUser1 = (amountIn * feeUser1) / 1e6;
        uint256 expectedFeeAmountUser1 = (feeAmountUser1 * DEFAULT_WINNER_FEE_SHARE) / 1e6;
        uint256 strategyUser1Balance = poolManager.balanceOf(address(strategyUser1), key.currency1.toId());
        assertEq(
            strategyUser1Balance,
            expectedFeeAmountUser1,
            "Strategy user1 did not receive correct fees after first swap"
        );

        uint80 user2RentPerBlock = 20e18;
        uint128 user2TotalRent = user2RentPerBlock * DEFAULT_MINIMUM_RENT_BLOCKS;
        uint128 user2AuctionFee = (user2TotalRent * hookAuctionFee) / 1e6;
        uint128 user2Deposit = user2TotalRent + user2AuctionFee;

        uint32 rentEndBlock2 = uint32(STARTING_BLOCK + 10 + DEFAULT_MINIMUM_RENT_BLOCKS);

        transferToAndDepositAs(user2Deposit, user2);
        vm.startPrank(user2);
        arbiterHook.overbid(key, user2RentPerBlock, rentEndBlock2, address(strategyUser2));
        vm.stopPrank();

        address currentWinner = arbiterHook.winner(key);
        assertEq(currentWinner, user2, "User2 should be the new winner");

        (uint128 initialRemainingRent, uint128 feeLocked, uint128 collectedFee) = arbiterHook.auctionFees(id);
        assertEq(feeLocked, user2AuctionFee, "Auction fee should be locked for user2");
        assertEq(initialRemainingRent, user2TotalRent, "Initial remaining rent should be equal to user2's total rent");

        uint128 feeRefund = uint128((uint256(user1AuctionFee) * remainingRentAfterSwapUser1) / user1TotalRent);
        assertEq(
            collectedFee,
            user1AuctionFee - feeRefund,
            "Collected fee should equal user1's auction fee minus the refunded portion"
        );

        moveBlockBy(10);

        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amountIn);
        swap(key, true, -int128(amountIn), ZERO_BYTES);

        uint256 feeAmountUser2 = (amountIn * feeUser2) / 1e6;
        uint256 expectedFeeAmountUser2 = (feeAmountUser2 * DEFAULT_WINNER_FEE_SHARE) / 1e6;
        uint256 strategyUser2Balance = poolManager.balanceOf(address(strategyUser2), key.currency1.toId());
        assertEq(
            strategyUser2Balance,
            expectedFeeAmountUser2,
            "Strategy user2 did not receive correct fees after second swap"
        );

        uint256 user1FinalDeposit = arbiterHook.depositOf(Currency.unwrap(currency0), user1);
        vm.startPrank(user1);
        arbiterHook.withdraw(Currency.unwrap(currency0), user1FinalDeposit);
        vm.stopPrank();

        uint256 user1FinalDepositAfter = arbiterHook.depositOf(Currency.unwrap(currency0), user1);
        assertEq(user1FinalDepositAfter, 0, "User1 should be able to withdraw the entire refunded deposit");

        uint256 user1BalancePostWithdraw = key.currency0.balanceOf(user1);
        assertTrue(
            user1BalancePostWithdraw >= user1BalancePreDeposit,
            "User1 should end up with at least their initial balance after refunds"
        );
    }
}
