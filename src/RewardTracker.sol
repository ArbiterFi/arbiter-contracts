// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "./libraries/PoolExtension.sol";
import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PositionInfo, PositionInfoLibrary} from "v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";

import {IRewardTracker} from "./interfaces/IRewardTracker.sol";
import {PoolExtension} from "./libraries/PoolExtension.sol";
import {PositionExtension} from "./libraries/PositionExtension.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

abstract contract RewardTracker is IRewardTracker {
    using PoolExtension for PoolExtension.State;
    using PositionExtension for PositionExtension.State;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    // using PoolGetters for Pool.State;
    // using PoolParametersHelper for bytes32;

    mapping(PoolId => PoolExtension.State) public pools;
    mapping(uint256 => PositionExtension.State) public positions;
    mapping(address => uint256) public accruedRewards;
    IPositionManager public immutable positionManager;

    modifier onlyPositionManager() {
        require(msg.sender == address(positionManager), "InRangeIncentiveHook: only position manager");
        _;
    }

    constructor(IPositionManager _positionManager) {
        positionManager = _positionManager;
    }

    // @dev this should be called before any rewards are distributed
    function _initialize(PoolId id, int24 tick) internal {
        console.log("[RewardTracker._initialize]");
        console.log("[RewardTracker._initialize] tick:", tick);
        pools[id].initialize(tick);
    }

    // @dev call it only after the pool was initialized
    function _distributeReward(PoolId id, uint128 rewards) internal {
        pools[id].distributeRewards(rewards);
    }

    // @dev call when the tick that receives rewards changes
    function _changeActiveTick(PoolId id, int24 newActiveTick, int24 tickSpacing) internal {
        console.log("[RewardTracker._changeActiveTick]");
        pools[id].crossToActiveTick(tickSpacing, newActiveTick);
    }

    function _accrueRewards(
        uint256 tokenId,
        address owner,
        uint128 positionLiquidity,
        uint256 rewardsPerLiquidityCumulativeX128
    ) internal {
        accruedRewards[owner] += positions[tokenId].accumulateRewards(
            positionLiquidity,
            rewardsPerLiquidityCumulativeX128
        );
    }

    //////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////// ISubscriber Implementation //////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////

    function _beforeOnSubscribeTracker(PoolKey memory key) internal virtual;

    function _onSubscribeTracker(uint256 tokenId) internal {
        console.log("[RewardTracker._onSubscribeTracker]");
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        _beforeOnSubscribeTracker(poolKey);
        pools[poolKey.toId()].modifyLiquidity(
            PoolExtension.ModifyLiquidityParams({
                tickLower: positionInfo.tickLower(),
                tickUpper: positionInfo.tickUpper(),
                liquidityDelta: int128(liquidity),
                tickSpacing: poolKey.tickSpacing
            })
        );

        positions[tokenId].initialize(
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(positionInfo.tickLower(), positionInfo.tickUpper())
        );
    }

    /// @inheritdoc ISubscriber
    function notifySubscribe(uint256 tokenId, bytes memory) external override onlyPositionManager {
        _onSubscribeTracker(tokenId);
    }

    function _beforeOnUnubscribeTracker(PoolKey memory key) internal virtual;

    function _onUnubscribeTracker(uint256 tokenId) internal {
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        _beforeOnUnubscribeTracker(poolKey);
        _accrueRewards(
            tokenId,
            IERC721(address(positionManager)).ownerOf(tokenId),
            liquidity,
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(positionInfo.tickLower(), positionInfo.tickUpper())
        );

        pools[poolKey.toId()].modifyLiquidity(
            PoolExtension.ModifyLiquidityParams({
                tickLower: positionInfo.tickLower(),
                tickUpper: positionInfo.tickUpper(),
                liquidityDelta: -int128(liquidity),
                tickSpacing: poolKey.tickSpacing
            })
        );

        delete positions[tokenId];
    }

    /// @inheritdoc ISubscriber
    function notifyUnsubscribe(uint256 tokenId) external override onlyPositionManager {
        _onUnubscribeTracker(tokenId);
    }

    function _beforeOnModifyLiquidityTracker(PoolKey memory key) internal virtual;

    function _onModifyLiquidityTracker(uint256 tokenId, int256 liquidityChange) internal {
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        _beforeOnModifyLiquidityTracker(poolKey);

        // take liquididty before the change
        uint128 liquidity = uint128(int128(positionManager.getPositionLiquidity(tokenId)) - int128(liquidityChange));

        _accrueRewards(
            tokenId,
            IERC721(address(positionManager)).ownerOf(tokenId),
            liquidity,
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(positionInfo.tickLower(), positionInfo.tickUpper())
        );

        pools[poolKey.toId()].modifyLiquidity(
            PoolExtension.ModifyLiquidityParams({
                tickLower: positionInfo.tickLower(),
                tickUpper: positionInfo.tickUpper(),
                liquidityDelta: int128(liquidityChange),
                tickSpacing: poolKey.tickSpacing
            })
        );
    }

    /// @inheritdoc ISubscriber
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta) external {
        _onModifyLiquidityTracker(tokenId, liquidityChange);
    }

    function _beforeOnNotifyTransferTracker(PoolKey memory key) internal virtual;

    function _onNotifyTransferTracker(uint256 tokenId, address previousOwner, address) internal {
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);

        // take liquididty before the change
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        _beforeOnNotifyTransferTracker(poolKey);

        _accrueRewards(
            tokenId,
            previousOwner,
            liquidity,
            pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(positionInfo.tickLower(), positionInfo.tickUpper())
        );
    }

    /// @inheritdoc ISubscriber
    function notifyTransfer(uint256 tokenId, address previousOwner, address newOwner) external override {
        _onNotifyTransferTracker(tokenId, previousOwner, newOwner);
    }

    function getRewardsPerLiquidityInsideX128(
        PoolKey calldata poolKey,
        int24 tickLower,
        int24 tickUpper
    ) external view override returns (uint256) {
        return pools[poolKey.toId()].getRewardsPerLiquidityInsideX128(tickLower, tickUpper);
    }

    function getRewardsPerLiquidityCumulativeX128(PoolKey calldata poolKey) external view override returns (uint256) {
        return pools[poolKey.toId()].getRewardsPerLiquidityCumulativeX128();
    }
}
