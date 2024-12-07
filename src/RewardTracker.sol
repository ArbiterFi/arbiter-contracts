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
import {IPoolKeys} from "./interfaces/IPoolKeys.sol";

abstract contract RewardTracker is IRewardTracker {
    using PoolExtension for PoolExtension.State;
    using PositionExtension for PositionExtension.State;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

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

    /// @dev MUST be called before any rewards are distributed
    /// @dev for example in beforeInitialize or afterInititalize hook
    function _initialize(PoolId id, int24 tick) internal {
        pools[id].initialize(tick);
    }

    /// @dev MUST be called only after the pool has been initialized
    /// @dev for example call it in before/afterSwap , before/afterModifyLiquididty hooks
    function _distributeReward(PoolId id, uint128 rewards) internal {
        pools[id].distributeRewards(rewards);
    }

    /// @dev MUST be called in afterSwap whenever the actibe tick changes
    function _handleActiveTickChange(PoolId id, int24 newActiveTick, int24 tickSpacing) internal {
        pools[id].crossToActiveTick(tickSpacing, newActiveTick);
    }

    /// @notice collects the accrued rewards for the caller
    /// @notice it's called at every Notification
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

    function _handleRemovePosition(
        uint256 tokenId,
        PoolKey memory key,
        PositionInfo positionInfo,
        uint128 liquidity
    ) internal {
        _accrueRewards(
            tokenId,
            IERC721(address(positionManager)).ownerOf(tokenId),
            liquidity,
            pools[key.toId()].getRewardsPerLiquidityInsideX128(positionInfo.tickLower(), positionInfo.tickUpper())
        );

        pools[key.toId()].modifyLiquidity(
            PoolExtension.ModifyLiquidityParams({
                tickLower: positionInfo.tickLower(),
                tickUpper: positionInfo.tickUpper(),
                liquidityDelta: -int128(liquidity),
                tickSpacing: key.tickSpacing
            })
        );

        delete positions[tokenId];
    }

    //////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////////// ISubscriber Implementation //////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////

    function _beforeOnSubscribeTracker(PoolKey memory key) internal virtual;

    /// @inheritdoc ISubscriber
    function notifySubscribe(uint256 tokenId, bytes memory) external override onlyPositionManager {
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

    function _beforeOnUnubscribeTracker(PoolKey memory key) internal virtual;

    /// @inheritdoc ISubscriber
    function notifyUnsubscribe(uint256 tokenId) external override onlyPositionManager {
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        _beforeOnUnubscribeTracker(poolKey);

        _handleRemovePosition(tokenId, poolKey, positionInfo, uint128(liquidity));
    }

    function _beforeOnBurnTracker(PoolKey memory key) internal virtual;

    /// @inheritdoc ISubscriber
    function notifyBurn(
        uint256 tokenId,
        address,
        PositionInfo positionInfo,
        uint256 liquidity,
        BalanceDelta
    ) external override {
        PoolKey memory poolKey = IPoolKeys(address(positionManager)).poolKeys(positionInfo.poolId());

        _beforeOnBurnTracker(poolKey);

        _handleRemovePosition(tokenId, poolKey, positionInfo, uint128(liquidity));
    }

    /**
     * @dev is called before modifying the liquidity tracker.
     * This function can be overridden to perform any actions that need to happen
     * upon a change in subscribed liquidity.
     *
     * @param key The PoolKey that identifies the liquidity pool being modified.
     */
    function _beforeOnModifyLiquidityTracker(PoolKey memory key) internal virtual;

    /// @inheritdoc ISubscriber
    function notifyModifyLiquidity(uint256 tokenId, int256 liquidityChange, BalanceDelta) external {
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
