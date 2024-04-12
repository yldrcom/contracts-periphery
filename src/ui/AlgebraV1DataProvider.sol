// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {BaseCLDataProvider} from "./BaseCLDataProvider.sol";
import {AlgebraV1Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/AlgebraV1Adapter.sol";

contract AlgebraV1DataProvider is BaseCLDataProvider, AlgebraV1Adapter {
    constructor(address _positionManager) AlgebraV1Adapter(_positionManager) {}
}
