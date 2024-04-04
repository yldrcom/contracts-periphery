// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {BaseCLAdapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/BaseCLAdapter.sol";

abstract contract BaseCLDataProvider is BaseCLAdapter {
    struct CLPositionData {
        uint256 tokenId;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickCurrent;
        int24 tickUpper;
        uint160 sqrtPriceX96;
        uint256 amount0;
        uint256 amount1;
        uint256 fee0;
        uint256 fee1;
        uint128 liquidity;
    }

    function getPositionData(uint256 tokenId) public view returns (CLPositionData memory) {
        PositionData memory position = _getPositionData(tokenId);
        address pool = _getPool(position);

        (uint160 sqrtPriceX96, int24 tickCurrent) = _getPoolState(pool);
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(position.tickLower),
            TickMath.getSqrtRatioAtTick(position.tickUpper),
            position.liquidity
        );
        (uint256 fees0, uint256 fees1) = _getPendingFees(position);

        return CLPositionData({
            tokenId: tokenId,
            token0: position.token0,
            token1: position.token1,
            fee: position.fee,
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

    function getPositionsData(uint256[] memory tokenIds) public view returns (CLPositionData[] memory datas) {
        datas = new CLPositionData[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            datas[i] = getPositionData(tokenIds[i]);
        }
    }

    function getPositionPool(uint256 tokenId) public view returns (address) {
        return _getPool(_getPositionData(tokenId));
    }

    function getPositionManager() public view returns (address) {
        return _getPositionManager();
    }

    function getFeeGrowths(address pool, int24 tick)
        public
        view
        returns (uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128)
    {
        return _getFeeGrowths(pool, tick);
    }

    function getPoolState(address pool) public view returns (uint160 sqrtPriceX96, int24 tick) {
        return _getPoolState(pool);
    }

    function getPoolLiquidity(address pool) public view returns (uint128 liquidity) {
        return _getPoolLiquidity(pool);
    }

    function getGlobalFeeGrowths(address pool)
        public
        view
        returns (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128)
    {
        return _getGlobalFeeGrowths(pool);
    }
}
