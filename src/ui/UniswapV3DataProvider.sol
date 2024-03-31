// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {BaseCLDataProvider} from "./BaseCLDataProvider.sol";
import {UniswapV3Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/UniswapV3Adapter.sol";

contract UniswapV3DataProvider is BaseCLDataProvider, UniswapV3Adapter {
    constructor(address _positionManager) UniswapV3Adapter(_positionManager) {}
}
