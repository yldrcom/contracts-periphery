// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {BaseERC1155CLWrapper} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/erc1155-wrappers/BaseERC1155CLWrapper.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {IYLDROracle} from "@yldr-lending/core/src/interfaces/IYLDROracle.sol";
import {IAssetConverter} from "src/interfaces/IAssetConverter.sol";
import {BaseCLLeveragedPosition} from "./BaseCLLeveragedPosition.sol";
import {
    UniswapV3Adapter,
    INonfungiblePositionManager
} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/UniswapV3Adapter.sol";
import {BaseERC1155CLWrapper} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/erc1155-wrappers/BaseERC1155CLWrapper.sol";

/// @author YLDR <admin@apyflow.com>
/// @notice This contract represents single leveraged position linked to a specific user
/// This contract's funds mainly stored in yldr protocol and consist of wrapped into ERC1155 Uniswap LP Position
/// and debt.
contract UniswapV3LeveragedPosition is BaseCLLeveragedPosition, UniswapV3Adapter {
    constructor(
        IPoolAddressesProvider _addressesProvider,
        BaseERC1155CLWrapper _positionWrapper,
        uint256 _revenueFeePercent,
        address _revenueFeeTreasury
    )
        UniswapV3Adapter(_positionWrapper.getPositionManager())
        BaseCLLeveragedPosition(_addressesProvider, _positionWrapper, _revenueFeePercent, _revenueFeeTreasury)
    {}
}
