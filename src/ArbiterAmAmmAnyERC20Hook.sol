// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SafeCast} from "lib/openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IArbiterFeeProvider} from "./interfaces/IArbiterFeeProvider.sol";

import {AuctionSlot0, AuctionSlot0Library} from "./types/AuctionSlot0.sol";
import {AuctionSlot1, AuctionSlot1Library} from "./types/AuctionSlot1.sol";

import {IArbiterAmAmmHarbergerLease} from "./interfaces/IArbiterAmAmmHarbergerLease.sol";
import {Ownable2Step} from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";

import {ArbiterAmAmmBaseHook} from "./ArbiterAmAmmBaseHook.sol";
import {RewardTracker} from "./RewardTracker.sol";

import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice ArbiterAmAmmBaseHook implements am-AMM auction and hook functionalities.
/// It allows anyone to bid for the right to collect and set trading fees for a pool after depositing the rent currency of the pool.
/// @dev The strategy address should implement IArbiterFeeProvider to set the trading fees.
/// @dev The strategy address should be able to manage ERC6909 claim tokens in the PoolManager.
///
/// @notice ArbiterAmAmmAnyERC20Hook uses immutable rentCurrency as the rent currency for all trading pairs.
/// @notice To recieve rent, Liquididty Providers must subscribe to this contract.
/// @notice To claim the rewards one must call collectRewards.
contract ArbiterAmAmmAnyERC20Hook is ArbiterAmAmmBaseHook, RewardTracker {
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Currency immutable rentCurrency;

    constructor(
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        address rentCurrency_,
        address initOwner_
    ) ArbiterAmAmmBaseHook(poolManager_, initOwner_) RewardTracker(positionManager_) {
        rentCurrency = Currency.wrap(rentCurrency_);
    }

    ///////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////// HOOK ///////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    /// @dev Reverts if dynamic fee flag is not set or if the pool is not initialized with dynamic fees.
    function beforeInitialize(address, PoolKey calldata key, uint160) external override returns (bytes4) {
        // Pool must have dynamic fee flag set. This is so we can override the LP fee in `beforeSwap`.
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        PoolId poolId = key.toId();

        (, int24 tick, , ) = poolManager.getSlot0(poolId);

        poolSlot0[poolId] = AuctionSlot0
            .wrap(bytes32(0))
            .setWinnerFeeSharePart(_defaultWinnerFeeShare)
            .setStrategyGasLimit(_defaultStrategyGasLimit)
            .setDefaultSwapFee(_defaultSwapFee)
            .setAuctionFee(_defaultAuctionFee)
            .setLastActiveTick(tick);

        _initialize(poolId, tick);

        return this.beforeInitialize.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        (, int24 tick, , ) = poolManager.getSlot0(poolId);

        AuctionSlot0 slot0 = poolSlot0[poolId];
        if (tick != slot0.lastActiveTick()) {
            _payRentAndChangeStrategyIfNeeded(key);
            _handleActiveTickChange(poolId, tick, key.tickSpacing);
        }

        return (this.afterSwap.selector, 0);
    }

    ///////////////////////////////////////////////////////////////////////////////////
    //////////////////////// ArbiterAmAmmBase Internal Overrides /////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    function _getPoolRentCurrency(PoolKey memory) internal view override returns (Currency) {
        return rentCurrency;
    }

    function _distributeRent(PoolKey memory key, uint128 rentAmount) internal override {
        _distributeReward(key.toId(), rentAmount);
    }

    ///////////////////////////////////////////////////////////////////////////////////
    //////////////////////////// RewardTracker Overrides //////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////

    function _beforeOnSubscribeTracker(PoolKey memory key) internal override {
        _payRentAndChangeStrategyIfNeeded(key);
    }

    function _beforeOnUnubscribeTracker(PoolKey memory key) internal override {
        _payRentAndChangeStrategyIfNeeded(key);
    }

    function _beforeOnModifyLiquidityTracker(PoolKey memory key) internal override {
        _payRentAndChangeStrategyIfNeeded(key);
    }

    function _beforeOnBurnTracker(PoolKey memory key) internal override {
        _payRentAndChangeStrategyIfNeeded(key);
    }

    function collectRewards(address to) external returns (uint256 rewards) {
        rewards = accruedRewards[msg.sender];
        accruedRewards[msg.sender] = 0;

        poolManager.unlock(abi.encode(CallbackData(Currency.unwrap(rentCurrency), to, 0, rewards)));
    }

    function donateRewards(PoolKey calldata key, uint128 rewards) external {
        deposits[msg.sender][rentCurrency] -= rewards;
        _distributeReward(key.toId(), rewards);
    }
}
