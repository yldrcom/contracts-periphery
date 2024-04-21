// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {BaseCLAdapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/BaseCLAdapter.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {YLDRCLLeverage} from "./YLDRCLLeverage.sol";
import {CLLeveragedPosition} from "./CLLeveragedPosition.sol";
import {CLAdapterWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/CLAdapterWrapper.sol";

/// @author YLDR <admin@apyflow.com>
contract CreateAndLeverage {
    using SafeERC20 for IERC20;
    using CLAdapterWrapper for BaseCLAdapter;

    YLDRCLLeverage public immutable leverage;
    BaseCLAdapter public immutable adapter;

    constructor(YLDRCLLeverage _leverage) {
        leverage = _leverage;
        adapter = CLLeveragedPosition(leverage.implementation()).positionWrapper().adapter();
    }

    function _approveIfNeeded(address token) internal {
        if (IERC20(token).allowance(address(this), adapter.getPositionManager()) == 0) {
            IERC20(token).forceApprove(adapter.getPositionManager(), type(uint256).max);
        }
    }

    function mint(BaseCLAdapter.MintParams memory mintParams, CLLeveragedPosition.PositionInitParams memory initParams)
        public
    {
        // If it's set to other address we will revert on safeTransfer, but update just in case
        mintParams.recipient = address(this);

        IERC20(mintParams.token0).safeTransferFrom(msg.sender, address(this), mintParams.amount0Desired);
        IERC20(mintParams.token1).safeTransferFrom(msg.sender, address(this), mintParams.amount1Desired);

        _approveIfNeeded(mintParams.token0);
        _approveIfNeeded(mintParams.token1);

        (uint256 tokenId,, uint256 amount0, uint256 amount1) = adapter.delegateMintPosition(mintParams);

        initParams.tokenId = tokenId;
        IERC721(adapter.getPositionManager()).safeTransferFrom(
            address(this), address(leverage), initParams.tokenId, abi.encode(initParams)
        );

        // Refund leftovers to user
        IERC20(mintParams.token0).safeTransfer(msg.sender, mintParams.amount0Desired - amount0);
        IERC20(mintParams.token1).safeTransfer(msg.sender, mintParams.amount1Desired - amount1);
    }
}
