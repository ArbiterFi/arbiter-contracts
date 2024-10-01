/// UNLICENSED
pragma solidity ^0.8.24;

import "./libraries/PoolExtension.sol";
import {BaseHook} from "lib/v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "lib/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "lib/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-core/src/types/PoolId.sol";
import {PositionInfo, PositionInfoLibrary} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {BalanceDelta} from "lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "lib/v4-core/src/types/BeforeSwapDelta.sol";
import {IERC721Receiver} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";
import {StateLibrary} from "lib/v4-core/src/libraries/StateLibrary.sol";
import {Slot0Library} from "lib/v4-core/src/types/Slot0.sol";

import {IERC721Receiver} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol";

contract LPIncentives is BaseHook, IERC721Receiver { 
    using StateLibrary for IPoolManager;
    using PoolExtension for PoolExtension.State;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    mapping(PoolId => PoolExtension.State) public pools;
    mapping(uint256 => address) public deposits;

    IPositionManager public immutable positionManager;

    constructor(IPoolManager _poolManager, IPositionManager _positionManager) BaseHook(_poolManager) {
    positionManager = _positionManager;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        override
        returns (bytes4)
    {
        pools[key.toId()].tick = tick;
        return BaseHook.afterInitialize.selector;
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        (, int24 tick, , ) = poolManager.getSlot0(key.toId()); 
        pools[key.toId()].crossToActiveTick(key.tickSpacing, tick);

        return (BaseHook.afterSwap.selector, 0);
    }

    /// @notice Upon receiving a Uniswap V4 ERC721, creates the token deposit setting owner to `from`. Also stakes token
    /// in one or more incentives if properly formatted `data` has a length > 0.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        
        returns (bytes4)
    {
        require(msg.sender == address(positionManager), "UniswapV4Staker::onERC721Received: not a univ4 nft");

        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);

        require(liquidity > 0, "UniswapV4Staker::onERC721Received: no liquidity");

        pools[poolKey.toId()].modifyLiquidity(PoolExtension.ModifyLiquidityParams({
            tickLower: positionInfo.tickLower(),
            tickUpper: positionInfo.tickUpper(),
            liquidityDelta: int128(liquidity),
            tickSpacing: poolKey.tickSpacing
        }));

        deposits[tokenId] = from;
       
        // emit DepositTransferred(tokenId, address(0), from);
        return this.onERC721Received.selector;
    }
}