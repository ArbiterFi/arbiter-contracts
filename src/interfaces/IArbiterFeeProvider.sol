// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";

interface IArbiterFeeProvider {
    function getFee(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external pure returns (uint24);
}
