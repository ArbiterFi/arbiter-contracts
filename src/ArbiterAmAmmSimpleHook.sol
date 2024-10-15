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

contract ArbiterAmAmmSimpleHook is BaseHook {
    using CurrencyLibrary for Currency;
    using LPFeeLibrary for uint24;
    using PoolIdLibrary for PoolKey;
    using SafeCast for int256;
    using SafeCast for uint256;

    error NotEnoughCollateral();
    error NotLiquidatable();
    error PoolMustBeDynamicFee();
    error SenderIsAlreadyStrategist();
    error RentTooLow();
    error RentTooLowDuringCooldown();
    error SenderMustBeStrategist();

    /// @notice State used within hooks.
    struct PoolHookState {
        address strategy;
        uint40 lastPaidBlock;
        bool rentInTokenZero;
        bool changeStrategy;
    }

    struct StrategistData {
        uint120 deposit;
        uint96 rentPerBlock;
        uint40 rentEndBlock;
    }

    /// @notice Data passed to `PoolManager.unlock` when distributing rent to LPs.
    struct CallbackData {
        PoolKey key;
        address sender;
        uint256 depositAmount;
        uint256 withdrawAmount;
    }

    mapping(PoolId => PoolHookState) public poolHookStates;
    mapping(PoolId => address) public winners;
    mapping(PoolId => address) public backers;
    mapping(PoolId => mapping(address => StrategistData)) public strategistDatas;

    uint24 DEFAULT_SWAP_FEE = 300; // 0.03%
    uint24 MAX_FEE = 3000; // 0.3% 

    uint256 RENT_FACTOR = 1.05e6; // Rent needs to be 5% higher to overvid current winner
    uint256 minimumRentTimeInBlocks = 300; // Minimum number of block for rent to be bided


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

    /// @notice Reverts if dynamic fee flag is not set.
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

    /// @notice Calculate swap fees from attached strategy and redirect the fees to the strategist.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        _payRent(key);

        // If no strategy is set, the swap fee is just set to the default fee like in a hookless Uniswap pool
        PoolHookState storage hookState = poolHookStates[key.toId()];
        if (hookState.strategy == address(0) || hookState.strategy == address(1)) {
            return
                (this.beforeSwap.selector, toBeforeSwapDelta(0, 0), DEFAULT_SWAP_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
        }

        // Call strategy contract to get swap fee.
        uint256 fee = DEFAULT_SWAP_FEE;
        try IArbiterFeeProvider(hookState.strategy).getFee(sender, key, params) returns (uint24 _fee) {
            if (_fee > MAX_FEE) {
                fee= MAX_FEE;
            } else {
            fee =  _fee;
            }
        } catch { }



        int256 fees = params.amountSpecified * int256(fee) / 1e6 - params.amountSpecified;
        uint256 absFees = fees < 0 ? uint256(-fees) : uint256(fees);
        // Determine the specified currency. If amountSpecified < 0, the swap is exact-in so the feeCurrency should be the token the swapper is selling.
        // If amountSpecified > 0, the swap is exact-out and it's the bought token.
        // TODO: check if this is correct
        bool exactOut = params.amountSpecified > 0;
        Currency feeCurrency = exactOut != params.zeroForOne ? key.currency0 : key.currency1;

        // // Send fees to `feeRecipient`
        poolManager.mint(hookState.strategy, feeCurrency.toId(), absFees);

        // Override LP fee to zero
        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(fees), 0), LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }


    ///////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// AmAMM //////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @notice Deposit tokens into this contract. Deposits are used to cover rent payments as the manager.
    function deposit(PoolKey calldata key, uint120 amount) external {
        // Deposit 6909 claim tokens to Uniswap V4 PoolManager. The claim tokens are owned by this contract.
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, amount, 0)));
        StrategistData storage strategistData = strategistDatas[key.toId()][msg.sender];
        strategistData.deposit += amount;
    }

     /// @notice Modify bid for a pool
    function bid(PoolKey calldata key, uint256 rent, uint40 rentEndBlock) external {
        require(rentEndBlock >= block.number + minimumRentTimeInBlocks, "Rent too short");
        _payRent(key);        
        address winner = winners[key.toId()];
        address backer = backers[key.toId()];

        StrategistData memory biderData = strategistDatas[key.toId()][winner];
        // for winner or backer rent must be higher unless current rent hes expired
        if (msg.sender == winner || msg.sender == backer) {
            require(rent > biderData.rentPerBlock * RENT_FACTOR/ 1e6 || biderData.rentEndBlock < block.number, "Error");   
        }

        // Revert if sender has to small deposit
        if (biderData.deposit < rent * (rentEndBlock - block.number)) {
            revert NotEnoughCollateral();
        }

        StrategistData storage strategistData = strategistDatas[key.toId()][msg.sender];
        strategistData.rentEndBlock = rentEndBlock;
        strategistData.rentPerBlock = uint96(rent);
    }

     /// @notice Withdraw tokens from this contract that were previously deposited with `depositCollateral`.
    function withdraw(PoolKey calldata key, uint120 amount) external {
        StrategistData memory senderData = strategistDatas[key.toId()][msg.sender];
        address winner = winners[key.toId()];
        address backer = backers[key.toId()];
        uint120 minDeposit = 0;
        PoolHookState memory poolHookState = poolHookStates[key.toId()];

        if ((msg.sender == winner || msg.sender == backer) && senderData.rentEndBlock > poolHookState.lastPaidBlock) {
            minDeposit = senderData.rentPerBlock * (senderData.rentEndBlock - poolHookState.lastPaidBlock);
        }

        require (senderData.deposit >= amount + minDeposit, "Deposit too low");

        senderData.deposit -= amount;

        // Withdraw 6909 claim tokens from Uniswap V4 PoolManager
        poolManager.unlock(abi.encode(CallbackData(key, msg.sender, 0, amount)));
    }

    function setWinner(PoolKey calldata key, address newWinner) external {
        address winner = winners[key.toId()];

        require (newWinner != winner, "Already winning");            

        StrategistData memory winnerData = strategistDatas[key.toId()][winner];
        StrategistData memory newWinnerData = strategistDatas[key.toId()][newWinner];

        require(newWinnerData.rentEndBlock > block.number && newWinnerData.rentPerBlock > winnerData.rentPerBlock * RENT_FACTOR / 1e6, "Error");

        backers[key.toId()] = winner;
        winners[key.toId()] = newWinner;

        poolHookStates[key.toId()].changeStrategy = true;
    }

    function setBacker(PoolKey calldata key, address newBacker) external {
        address backer = backers[key.toId()];
        require (newBacker != backer, "Already backing");     

        address winner = winners[key.toId()];       
        require(newBacker != winner, "Already winning");

        StrategistData memory backerData = strategistDatas[key.toId()][backer];
        StrategistData memory newBackerData = strategistDatas[key.toId()][newBacker];
        StrategistData memory winnerData = strategistDatas[key.toId()][winner];

        uint40 minimumBlock = uint40(block.number) > winnerData.rentEndBlock ? uint40(block.number) : winnerData.rentEndBlock;

        require(newBackerData.rentEndBlock > minimumBlock && newBackerData.rentPerBlock > backerData.rentPerBlock * RENT_FACTOR / 1e6, "Error");

        backers[key.toId()] = newBacker;    
    } 

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Callback ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////   

    /// @notice Deposit or withdraw 6909 claim tokens and distribute rent to LPs.
    function _unlockCallback(bytes calldata rawData) internal override returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        _payRent(data.key);
        if (data.depositAmount > 0) {
            PoolHookState storage poolHookState = poolHookStates[data.key.toId()];
            Currency currency = poolHookState.rentInTokenZero ? data.key.currency0 : data.key.currency1;
            poolManager.burn(data.sender, currency.toId(), data.depositAmount); 
            poolManager.mint(address(this),currency.toId(), data.depositAmount); 
        }
        if (data.withdrawAmount > 0) {
            PoolHookState storage poolHookState = poolHookStates[data.key.toId()];
            Currency currency = poolHookState.rentInTokenZero ? data.key.currency0 : data.key.currency1;
           poolManager.burn(address(this), currency.toId(), data.withdrawAmount); 
            poolManager.mint(data.sender,currency.toId(), data.withdrawAmount); 
        }
        return "";
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////// Internal ////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////


    /// @dev Must be called while lock is acquired.
    function _payRent(PoolKey memory key) internal returns (address) {
        PoolHookState memory hookState = poolHookStates[key.toId()];

        if (hookState.lastPaidBlock == block.number) {
            return hookState.strategy;
        }

        // check if we need to change strategy
        if (hookState.changeStrategy && hookState.lastPaidBlock != block.number) {
            hookState.strategy = winners[key.toId()];
            hookState.changeStrategy = false;
        }

        StrategistData memory strategistData = strategistDatas[key.toId()][hookState.strategy];

        uint40 blocksElapsed = strategistData.rentEndBlock > uint40(block.number)
            ? uint40(block.number) - hookState.lastPaidBlock
            : strategistData.rentEndBlock - hookState.lastPaidBlock;

        hookState.lastPaidBlock = uint40(block.number);

        if (blocksElapsed == 0) return hookState.strategy;

        uint120 rentAmount = strategistData.rentPerBlock * blocksElapsed;

        strategistData.deposit -= rentAmount;
        strategistDatas[key.toId()][hookState.strategy] = strategistData;
        poolHookStates[key.toId()] = hookState;


        if( hookState.rentInTokenZero){
            Currency currency =  key.currency0;
            poolManager.burn(address(this),currency.toId(), rentAmount); 
            poolManager.donate(key, rentAmount, 0, "");
        } else {
            Currency currency =  key.currency1;
            poolManager.burn(address(this),currency.toId(),  rentAmount); 
            poolManager.donate(key, 0, rentAmount, "");
        }

        return hookState.strategy;
    }
}
