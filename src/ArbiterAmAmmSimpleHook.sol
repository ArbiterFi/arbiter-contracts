// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BalanceDelta, toBalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
import {BaseHook} from "lib/v4-periphery/src/base/hooks/BaseHook.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "lib/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "lib/v4-core/src/types/Currency.sol";
import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {TickMath} from "lib/v4-core/src/libraries/TickMath.sol";

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Minimal} from "lib/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {IArbiterFeeProvider} from "./interfaces/IArbiterFeeProvider.sol";
import {IUnlockCallback} from "lib/v4-core/src/interfaces/callback/IUnlockCallback.sol";

/// @notice ArbiterAmAmmSimpleHook implements am-AMM auction and hook functionalites.
/// It allows anyone to bid for the right to collect and set trading fees for a pool after depositing the rent currency of the pool.
/// @dev The winner address should implement IArbiterFeeProvider to set the trading fees.
/// @dev The winner address should be able to manage ERC6909 claim tokens in the PoolManager.
contract ArbiterAmAmmSimpleHook is BaseHook {
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;

    error ToSmallDeposit();
    error PoolMustBeDynamicFee();
    error AlreadyWinning();
    error RentTooLow();

    /// @notice State used within hooks.
    struct PoolHookState {
        address strategy;
        uint88 rentPerBlock;
        bool changeStrategy;
        bool rentInTokenZero;
    }

    struct RentData {
        uint128 remainingRent;
        uint64 lastPaidBlock;
        uint64 rentEndBlock;
    }

    /// @notice Data passed to `PoolManager.unlock` when distributing rent to LPs.
    struct CallbackData {
        PoolKey key;
        address sender;
        uint256 depositAmount;
        uint256 withdrawAmount;
    }

    mapping(PoolId => PoolHookState) public poolHookStates;
    mapping(PoolId => RentData) public rentDatas;
    mapping(PoolId => address) public winners;
    mapping(address => mapping(Currency => uint256)) public deposits;

    uint24 DEFAULT_SWAP_FEE = 300; // 0.03%
    uint24 MAX_FEE = 3000; // 0.3%

    uint256 RENT_FACTOR = 1.05e6; // Rent needs to be 5% higher to overvid current winner
    uint64 minimumRentTimeInBlocks = 300; // Minimum number of block for rent to be bided
    uint64 transitionBlocks = 3; // In the last 3 blocks of rent one can be overbided by any amount

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    ///////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// HOOK ///////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Specify hook permissions. `beforeSwapReturnDelta` is also set to charge custom swap fees that go to the strategist instead of LPs.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Reverts if dynamic fee flag is not set or if the pool is not intialized with dynamic fees.
    function beforeInitialize(address, PoolKey calldata key, uint160, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicFee()) revert PoolMustBeDynamicFee();
        return this.beforeInitialize.selector;

        //TODO: revert if calldata doesnt pass bool to set the rent in token0
    }

    /// @notice Distributes rent to LPs before each liquidity change.
    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        _payRent(key);
        return this.beforeAddLiquidity.selector;
    }

    /// @notice Distributes rent to LPs before each swap.
    /// @notice Returns fee what will be paid to the hook and pays the fee to the strategist.
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        address strategy = _payRent(key);

        // If no strategy is set, the swap fee is just set to the default fee like in a hookless Uniswap pool
        if (strategy == address(0)) {
            return
                (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), DEFAULT_SWAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        // Call strategy contract to get swap fee.
        uint256 fee = DEFAULT_SWAP_FEE;
        try IArbiterFeeProvider(strategy).getFee(sender, key, params) returns (uint24 _fee) {
            if (_fee > MAX_FEE) {
                fee = MAX_FEE;
            } else {
                fee = _fee;
            }
        } catch {}

        int256 fees = params.amountSpecified * int256(fee) / 1e6 - params.amountSpecified;
        uint256 absFees = fees < 0 ? uint256(-fees) : uint256(fees);
        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in so the feeCurrency should be the token the swapper is selling.
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.
        // TODO: check if this is correct
        bool exactOut = params.amountSpecified > 0;
        Currency feeCurrency = exactOut != params.zeroForOne ? key.currency0 : key.currency1;

        // // Send fees to `feeRecipient`
        poolManager.mint(strategy, feeCurrency.toId(), absFees);

        // Override LP fee to zero
        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(fees), 0), LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// AmAMM //////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Deposit tokens into this contract. Deposits are used to cover rent payments as the manager.
    function makeDeposit(PoolKey calldata key, uint256 amount) external {
        require( rentDatas[key.toId()].lastPaidBlock != 0, "Pool not initialized");  
        // Deposit 6909 claim tokens to Uniswap V4 PoolManager. The claim tokens are owned by this contract.
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, amount, 0)));
        deposits[msg.sender][_getPoolRentCurrency(key)] += amount;
    }

    /// @notice Place a winning bid - once won the sender address will receive all swap fees and will be called to provide fee.
    /// @dev The rent must be higher than the current rent by RENT_FACTOR unless the current rent is in the last transitionBlocks blocks
    /// @dev The rentEndBlock must be at least minimumRentTimeInBlocks in the future
    /// @dev The sender must have enough deposit to cover the rent
    function bid(PoolKey calldata key, uint88 rent, uint64 rentEndBlock) external {
        require(rentEndBlock >= block.number + minimumRentTimeInBlocks, "Rent too short");

        RentData memory rentData = rentDatas[key.toId()];
        PoolHookState memory hookState = poolHookStates[key.toId()];
        if (block.number < rentData.rentEndBlock - transitionBlocks) {
            require(rent > hookState.rentPerBlock * RENT_FACTOR / 1e6, "Rent too low");
        }

        _payRent(key);

        Currency currency = _getPoolRentCurrency(key);

        // refund the remaining rent to the previous winner
        deposits[winners[key.toId()]][currency] += rentData.remainingRent;

        // charge the new winner
        uint128 requiredDeposit = rent * (rentEndBlock - uint64(block.number));
        require(deposits[msg.sender][currency] >= requiredDeposit, "Deposit too low");
        deposits[msg.sender][currency] -= requiredDeposit;

        // set up new rent
        rentData.remainingRent = requiredDeposit;
        rentData.rentEndBlock = rentEndBlock;
        hookState.rentPerBlock = rent;
        hookState.changeStrategy = true;

        rentDatas[key.toId()] = rentData;
        poolHookStates[key.toId()] = hookState;
        winners[key.toId()] = msg.sender;
    }

    /// @notice Withdraw tokens from this contract that were previously deposited with `depositCollateral`.
    function withdraw(PoolKey calldata key, uint128 amount) external {
        Currency currency = _getPoolRentCurrency(key);
        uint256 deposit = deposits[msg.sender][currency];
        unchecked {
            require(deposit >= amount, "Deposit too low");
            deposits[msg.sender][currency] = deposit - amount;
        }
        // Withdraw 6909 claim tokens from Uniswap V4 PoolManager
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, 0, amount)));
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Callback ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Deposit or withdraw 6909 claim tokens and distribute rent to LPs.
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        _payRent(data.key);
        if (data.depositAmount > 0) {
            Currency currency = _getPoolRentCurrency(data.key);
            poolManager.burn(data.sender, currency.toId(), data.depositAmount);
            poolManager.mint(address(this), currency.toId(), data.depositAmount);
        }
        if (data.withdrawAmount > 0) {
            Currency currency = _getPoolRentCurrency(data.key);
            poolManager.burn(address(this), currency.toId(), data.withdrawAmount);
            poolManager.mint(data.sender, currency.toId(), data.withdrawAmount);
        }
        return "";
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Internal ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @dev Must be called while lock is acquired.
    function _payRent(PoolKey memory key) internal returns (address) {
        RentData memory rentData = rentDatas[key.toId()];
        PoolHookState memory hookState = poolHookStates[key.toId()];

        if (rentData.lastPaidBlock == block.number) {
            return hookState.strategy;
        }


        // check if we need to change strategy
        if (hookState.changeStrategy && rentData.lastPaidBlock != block.number) {
            hookState.strategy = winners[key.toId()];
            hookState.changeStrategy = false;
        }

        uint64 blocksElapsed;
        if (rentData.rentEndBlock <= uint64(block.number)) {
            blocksElapsed = rentData.rentEndBlock - rentData.lastPaidBlock;
            winners[key.toId()] = address(0);
            hookState.changeStrategy = true;
            hookState.rentPerBlock = 0;
            poolHookStates[key.toId()] = hookState;
        } else {
            blocksElapsed = uint64(block.number) - rentData.lastPaidBlock;
        }

        rentData.lastPaidBlock = uint64(block.number);

        uint128 rentAmount = hookState.rentPerBlock * blocksElapsed;

        rentData.remainingRent -= rentAmount;
        rentDatas[key.toId()] = rentData;

        if (rentAmount == 0) {
            return hookState.strategy;
        }

        // pay the rent
        if (hookState.rentInTokenZero) {
            Currency currency = key.currency0;
            poolManager.burn(address(this), currency.toId(), rentAmount);
            poolManager.donate(key, rentAmount, 0, "");
        } else {
            Currency currency = key.currency1;
            poolManager.burn(address(this), currency.toId(), rentAmount);
            poolManager.donate(key, 0, rentAmount, "");
        }

        return hookState.strategy;
    }

    function _getPoolRentCurrency(PoolKey memory key) internal view returns (Currency) {
        return poolHookStates[key.toId()].rentInTokenZero ? key.currency0 : key.currency1;
    }
        
}
