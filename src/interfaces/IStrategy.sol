// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {IArbiterFeeProvider} from "./IArbiterFeeProvider.sol";

interface IStrategy is IArbiterFeeProvider {
    /// @notice Collects fees from the PoolManager
    /// @param key The key of the pool to collect fees from
    function collectFees(PoolKey calldata key) external;
}
