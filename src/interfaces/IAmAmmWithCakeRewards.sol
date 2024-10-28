// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IArbiterHarbergerLease} from "./IArbiterHarbergerLease.sol";
import {ILiquididityPerSecondTrackerHook} from "./ILiquididityPerSecondTrackerHook.sol";
import {PoolKey} from "lib/pancake-v4-core/src/types/PoolKey.sol";

/// @title amAMM With Cake Rewards Interface
/// @notice This interface combines the Harberger Lease and Liquidity Per Second Tracker hooks
/// to allow for bidding and distributing rewards to any pool with CAKE token.
/// @notice To be eligible for rewards, users must subscrbe to the pool ILiquididityPerSecondTrackerHook::INotifier.
/// @notice ILiquididityPerSecondTrackerHook is used to track the liquidity per second of subscribed liquidity within pools like in V3.
/// @notice The rewards are distributed to the subscribers based on the liquidity per second of the subscribed liquidity.
interface IAmAmmWithCakeRewards is IArbiterHarbergerLease, ILiquididityPerSecondTrackerHook {
    /// @notice Collects the rewards for the pool for the msg.sender
    /// @param key The key of the pool to collect rewards from
    function collectRewards(PoolKey calldata key) external;
}
