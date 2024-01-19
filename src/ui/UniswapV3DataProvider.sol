// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {UniswapV3Position} from "@yldr-lending/core/src/protocol/concentrated-liquidity/libraries/UniswapV3Position.sol";
import {IUniswapV3DataProvider} from "../interfaces/IUniswapV3DataProvider.sol";

contract UniswapV3DataProvider is IUniswapV3DataProvider {
    using UniswapV3Position for UniswapV3Position.UniswapV3PositionData;

    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable factory;

    constructor(INonfungiblePositionManager _positionManager) {
        positionManager = _positionManager;
        factory = IUniswapV3Factory(_positionManager.factory());
    }

    function getPositionData(uint256 tokenId) public view returns (PositionData memory) {
        UniswapV3Position.UniswapV3PositionData memory position =
            UniswapV3Position.get(positionManager, factory, tokenId);

        (uint160 sqrtPriceX96, int24 tickCurrent,,,,,) = position.pool.slot0();
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(position.tickLower),
            TickMath.getSqrtRatioAtTick(position.tickUpper),
            position.liquidity
        );
        (uint256 fees0, uint256 fees1) = position.getPendingFees();

        return PositionData({
            tokenId: tokenId,
            token0: position.token0,
            token1: position.token1,
            fee: position.pool.fee(),
            tickLower: position.tickLower,
            tickCurrent: tickCurrent,
            tickUpper: position.tickUpper,
            sqrtPriceX96: sqrtPriceX96,
            amount0: amount0,
            amount1: amount1,
            fee0: fees0,
            fee1: fees1,
            liquidity: position.liquidity
        });
    }

    function getPositionsData(uint256[] memory tokenIds) public view returns (PositionData[] memory datas) {
        datas = new PositionData[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            datas[i] = getPositionData(tokenIds[i]);
        }
    }
}
