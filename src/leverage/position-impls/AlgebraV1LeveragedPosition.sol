// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {BaseERC1155CLWrapper} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/erc1155-wrappers/BaseERC1155CLWrapper.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {BaseCLLeveragedPosition} from "./BaseCLLeveragedPosition.sol";
import {AlgebraV1Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/AlgebraV1Adapter.sol";

/// @author YLDR <admin@apyflow.com>
contract AlgebraV1LeveragedPosition is BaseCLLeveragedPosition, AlgebraV1Adapter {
    constructor(
        IPoolAddressesProvider _addressesProvider,
        BaseERC1155CLWrapper _positionWrapper,
        uint256 _revenueFeePercent,
        address _revenueFeeTreasury
    )
        AlgebraV1Adapter(_positionWrapper.getPositionManager())
        BaseCLLeveragedPosition(_addressesProvider, _positionWrapper, _revenueFeePercent, _revenueFeeTreasury)
    {}
}
