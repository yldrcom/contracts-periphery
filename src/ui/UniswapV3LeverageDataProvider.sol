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
import {IUniswapV3LeverageDataProvider} from "../interfaces/IUniswapV3LeverageDataProvider.sol";
import {UniswapV3LeveragedPosition} from "../leverage/UniswapV3LeveragedPosition.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";

contract UniswapV3LeverageDataProvider is IUniswapV3LeverageDataProvider {
    IUniswapV3DataProvider public immutable uniswapV3DataProvider;

    constructor(IUniswapV3DataProvider _uniswapV3DataProvider) {
        uniswapV3DataProvider = _uniswapV3DataProvider;
    }

    function getPositionData(address position) public view returns (PositionData memory) {
        uint256 tokenId = UniswapV3LeveragedPosition(position).positionTokenId();
        IUniswapV3DataProvider.PositionData memory positionData = uniswapV3DataProvider.getPositionData(tokenId);
        address debtAsset = UniswapV3LeveragedPosition(position).borrowedToken();
        IPoolAddressesProvider addressesProvider = UniswapV3LeveragedPosition(position).addressesProvider();
        IPool pool = IPool(addressesProvider.getPool());
        uint256 debt = IERC20(pool.getReserveData(debtAsset).variableDebtTokenAddress).balanceOf(position);

        return PositionData({uniswapV3Position: positionData, debt: debt, debtAsset: debtAsset});
    }

    function getPositionsData(address[] memory positions) public view returns (PositionData[] memory datas) {
        datas = new PositionData[](positions.length);
        for (uint256 i = 0; i < positions.length; i++) {
            datas[i] = getPositionData(positions[i]);
        }
    }
}
