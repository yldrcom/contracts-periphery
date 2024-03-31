// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {BaseERC1155CLWrapper} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/erc1155-wrappers/BaseERC1155CLWrapper.sol";
import {YLDRCLLeverage, BaseCLLeveragedPosition} from "../YLDRCLLeverage.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {BaseCLAdapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/BaseCLAdapter.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @author YLDR <admin@apyflow.com>
abstract contract BaseCreateAndLeverage is BaseCLAdapter {
    using SafeERC20 for IERC20;

    YLDRCLLeverage public immutable leverage;

    constructor(YLDRCLLeverage _leverage) {
        leverage = _leverage;
    }

    function _approveIfNeeded(address token) internal {
        if (IERC20(token).allowance(address(this), _getPositionManager()) == 0) {
            IERC20(token).forceApprove(_getPositionManager(), type(uint256).max);
        }
    }

    function mint(MintParams memory mintParams, BaseCLLeveragedPosition.PositionInitParams memory initParams) public {
        // If it's set to other address we will revert on safeTransfer, but update just in case
        mintParams.recipient = address(this);

        IERC20(mintParams.token0).safeTransferFrom(msg.sender, address(this), mintParams.amount0Desired);
        IERC20(mintParams.token1).safeTransferFrom(msg.sender, address(this), mintParams.amount1Desired);

        _approveIfNeeded(mintParams.token0);
        _approveIfNeeded(mintParams.token1);

        (uint256 tokenId,, uint256 amount0, uint256 amount1) = _mintPosition(mintParams);

        initParams.tokenId = tokenId;
        IERC721(_getPositionManager()).safeTransferFrom(
            address(this), address(leverage), initParams.tokenId, abi.encode(initParams)
        );

        // Refund leftovers to user
        IERC20(mintParams.token0).safeTransfer(msg.sender, mintParams.amount0Desired - amount0);
        IERC20(mintParams.token1).safeTransfer(msg.sender, mintParams.amount1Desired - amount1);
    }
}
