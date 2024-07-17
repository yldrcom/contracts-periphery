// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {CLDataProvider} from "./CLDataProvider.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {ERC20Leverage} from "../erc20-leverage/ERC20Leverage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ALMLeveragedPosition} from "../alm/ALMLeveragedPosition.sol";
import {BaseALMAdapter} from "../alm/alm-adapters/BaseALMAdapter.sol";

contract ALMLeverageDataProvider {
    struct ALMLeveragedPositionData {
        address token0;
        address token1;
        address vault;
        uint256 shares;
        uint256 amount0;
        uint256 amount1;
        address debtAsset;
        uint256 debt;
    }

    ERC20Leverage public immutable leverage;

    constructor(ERC20Leverage _leverage) {
        leverage = _leverage;
    }

    function getPositionData(address _position) public view returns (ALMLeveragedPositionData memory) {
        ALMLeveragedPosition position = ALMLeveragedPosition(_position);
        IPoolAddressesProvider addressesProvider = position.addressesProvider();
        IPool pool = IPool(addressesProvider.getPool());

        address vault = position.lpToken();
        uint256 shares = IERC20(vault).balanceOf(address(position));
        address debtAsset = position.tokenToBorrow();
        uint256 debt = IERC20(pool.getReserveData(debtAsset).variableDebtTokenAddress).balanceOf(_position);

        BaseALMAdapter adapter = position.adapter();
        (address token0, address token1) = adapter.getVaultTokens(vault);
        (uint256 total0, uint256 total1) = adapter.getVaultAmounts(vault);

        uint256 totalSupply = IERC20(vault).totalSupply();
        uint256 amount0 = total0 * shares / totalSupply;
        uint256 amount1 = total1 * shares / totalSupply;

        return ALMLeveragedPositionData({
            shares: shares,
            debt: debt,
            token0: token0,
            token1: token1,
            debtAsset: debtAsset,
            amount0: amount0,
            amount1: amount1,
            vault: vault
        });
    }

    function getPositionsData(address[] memory positions)
        public
        view
        returns (ALMLeveragedPositionData[] memory datas)
    {
        datas = new ALMLeveragedPositionData[](positions.length);
        for (uint256 i = 0; i < positions.length; i++) {
            datas[i] = getPositionData(positions[i]);
        }
    }
}
