// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ISubscriber} from "v4-periphery/src/interfaces/ISubscriber.sol";

/// @title Liquidity Per Second Tracker
/// @notice This hook is used to track the liquidity per second of subscribed liquidity within pools like in V3.
interface IRewardTracker is ISubscriber {
    /// @return The seconds per **subscribed** liquidity cumulative for the pool
    /// @param key The key of the pool to check
    function getRewardsPerLiquidityCumulativeX128(PoolKey calldata key) external view returns (uint256);

    /// @return The seconds per **subscribed** liquidity inside the tick range
    /// @param key The key of the pool to check
    /// @param tickLower The lower tick of the range
    function getRewardsPerLiquidityInsideX128(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256);
}