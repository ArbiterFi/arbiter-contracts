// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title Interface to expose mapping(bytes25 poolId => PoolKey poolKey) public poolKeys;
/// @notice Interface for the PositionManager contract to expose poolKeys;
interface IPoolKeys {
    function poolKeys(bytes25 poolId) external view returns (PoolKey memory);
}
