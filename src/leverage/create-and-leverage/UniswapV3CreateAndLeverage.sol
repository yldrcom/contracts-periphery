// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {BaseERC1155CLWrapper} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/erc1155-wrappers/BaseERC1155CLWrapper.sol";
import {YLDRCLLeverage, BaseCLLeveragedPosition} from "../YLDRCLLeverage.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {UniswapV3Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/UniswapV3Adapter.sol";
import {BaseCreateAndLeverage} from "./BaseCreateAndLeverage.sol";

/// @author YLDR <admin@apyflow.com>
contract UniswapV3CreateAndLeverage is BaseCreateAndLeverage, UniswapV3Adapter {
    constructor(YLDRCLLeverage _leverage)
        BaseCreateAndLeverage(_leverage)
        UniswapV3Adapter(
            BaseERC1155CLWrapper(BaseCLLeveragedPosition(_leverage.implementation()).positionWrapper()).getPositionManager()
        )
    {}
}
