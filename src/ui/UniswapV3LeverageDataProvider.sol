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
import {IUniswapV3Leverage} from "../interfaces/IUniswapV3Leverage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniswapV3LeveragedPosition} from "../leverage/UniswapV3LeveragedPosition.sol";

contract UniswapV3LeverageDataProvider is IUniswapV3LeverageDataProvider {
    IUniswapV3DataProvider public immutable uniswapV3DataProvider;
    IUniswapV3Leverage public immutable uniswapV3Leverage;

    constructor(IUniswapV3DataProvider _uniswapV3DataProvider, IUniswapV3Leverage _uniswapV3Leverage) {
        uniswapV3DataProvider = _uniswapV3DataProvider;
        uniswapV3Leverage = _uniswapV3Leverage;
    }

    function getGlobalRevenueFee() public view returns (uint256) {
        return UniswapV3LeveragedPosition(uniswapV3Leverage.implementation()).revenueFeePercent();
    }

    function getPositionData(address _position) public view returns (PositionData memory) {
        UniswapV3LeveragedPosition position = UniswapV3LeveragedPosition(_position);
        uint256 tokenId = position.positionTokenId();
        IUniswapV3DataProvider.PositionData memory positionData = uniswapV3DataProvider.getPositionData(tokenId);
        address debtAsset = position.borrowedToken();
        IPoolAddressesProvider addressesProvider = position.addressesProvider();
        IPool pool = IPool(addressesProvider.getPool());
        uint256 debt = IERC20(pool.getReserveData(debtAsset).variableDebtTokenAddress).balanceOf(_position);

        (uint256 lastFees0, uint256 lastFees1) = (position.lastFees0(), position.lastFees1());
        uint256 revenueFeePercent = position.revenueFee();
        uint256 revenueFee0 = Math.mulDiv(positionData.fee0 - lastFees0, revenueFeePercent, 1e4);
        uint256 revenueFee1 = Math.mulDiv(positionData.fee1 - lastFees1, revenueFeePercent, 1e4);

        return PositionData({
            uniswapV3Position: positionData,
            debt: debt,
            debtAsset: debtAsset,
            revenueFee0: revenueFee0,
            revenueFee1: revenueFee1,
            revenueFeePercent: revenueFeePercent
        });
    }

    function getPositionsData(address[] memory positions) public view returns (PositionData[] memory datas) {
        datas = new PositionData[](positions.length);
        for (uint256 i = 0; i < positions.length; i++) {
            datas[i] = getPositionData(positions[i]);
        }
    }
}
