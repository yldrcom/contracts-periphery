// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {CLDataProvider} from "./CLDataProvider.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {YLDRCLLeverage} from "../leverage/YLDRCLLeverage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CLLeveragedPosition} from "../leverage/CLLeveragedPosition.sol";

contract CLLeverageDataProvider {
    struct LeveragedCLPositionData {
        CLDataProvider.CLPositionData uniswapV3Position;
        address debtAsset;
        uint256 debt;
        uint256 revenueFee0;
        uint256 revenueFee1;
        uint256 revenueFeePercent;
    }

    CLDataProvider public immutable dataProvider;
    YLDRCLLeverage public immutable leverage;

    constructor(CLDataProvider _dataProvider, YLDRCLLeverage _leverage) {
        dataProvider = _dataProvider;
        leverage = _leverage;

        require(
            dataProvider.adapter() == CLLeveragedPosition(_leverage.implementation()).positionWrapper().adapter(),
            "INVALID_ADAPTER"
        );
    }

    function getGlobalRevenueFee() public view returns (uint256) {
        return CLLeveragedPosition(leverage.implementation()).revenueFeePercent();
    }

    function getPositionData(address _position) public view returns (LeveragedCLPositionData memory) {
        CLLeveragedPosition position = CLLeveragedPosition(_position);
        IPoolAddressesProvider addressesProvider = position.addressesProvider();
        IPool pool = IPool(addressesProvider.getPool());

        uint256 tokenId = position.positionTokenId();
        CLDataProvider.CLPositionData memory positionData = dataProvider.getPositionData(tokenId);
        address debtAsset = position.borrowedToken();
        uint256 debt = IERC20(pool.getReserveData(debtAsset).variableDebtTokenAddress).balanceOf(_position);

        (uint256 lastFees0, uint256 lastFees1) = (position.lastFees0(), position.lastFees1());
        uint256 revenueFeePercent = position.revenueFee();
        uint256 revenueFee0 =
            (positionData.fee0 > lastFees0) ? (positionData.fee0 - lastFees0) * revenueFeePercent / 1e4 : 0;
        uint256 revenueFee1 =
            (positionData.fee1 > lastFees1) ? (positionData.fee1 - lastFees1) * revenueFeePercent / 1e4 : 0;

        return LeveragedCLPositionData({
            uniswapV3Position: positionData,
            debt: debt,
            debtAsset: debtAsset,
            revenueFee0: revenueFee0,
            revenueFee1: revenueFee1,
            revenueFeePercent: revenueFeePercent
        });
    }

    function getPositionsData(address[] memory positions)
        public
        view
        returns (LeveragedCLPositionData[] memory datas)
    {
        datas = new LeveragedCLPositionData[](positions.length);
        for (uint256 i = 0; i < positions.length; i++) {
            datas[i] = getPositionData(positions[i]);
        }
    }
}
