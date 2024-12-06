// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IArbiterFeeProvider {
    /// @return The fee for the swap
    /// @dev Must cost less than GET_SWAP_FEE_GAS_LIMIT
    /// @param sender The address of the swap sender
    /// @param key The key of the pool to swap in
    /// @param params The swap parameters
    /// @param hookData The hook data
    function getSwapFee(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external view returns (uint24);
}
