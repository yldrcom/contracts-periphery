// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {BaseERC1155CLWrapper} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/erc1155-wrappers/BaseERC1155CLWrapper.sol";
import {YLDRCLLeverage, BaseCLLeveragedPosition} from "../YLDRCLLeverage.sol";
import {AlgebraV1Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/AlgebraV1Adapter.sol";
import {BaseCreateAndLeverage} from "./BaseCreateAndLeverage.sol";

/// @author YLDR <admin@apyflow.com>
contract AlgebraV1CreateAndLeverage is BaseCreateAndLeverage, AlgebraV1Adapter {
    constructor(YLDRCLLeverage _leverage)
        BaseCreateAndLeverage(_leverage)
        AlgebraV1Adapter(
            BaseERC1155CLWrapper(BaseCLLeveragedPosition(_leverage.implementation()).positionWrapper()).getPositionManager()
        )
    {}
}
