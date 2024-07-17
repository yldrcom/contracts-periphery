// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ALMLeveragedPosition} from "./ALMLeveragedPosition.sol";
import {BaseALMAdapter} from "./alm-adapters/BaseALMAdapter.sol";
import {ALMAdapterWrapper} from "./ALMAdapterWrapper.sol";
import {ERC20Leverage} from "../erc20-leverage/ERC20Leverage.sol";

/// @author YLDR <admin@apyflow.com>
contract ALMCreateAndLeverage {
    using SafeERC20 for IERC20;
    using ALMAdapterWrapper for BaseALMAdapter;

    ERC20Leverage public immutable leverage;
    BaseALMAdapter public immutable adapter;

    constructor(ERC20Leverage _leverage) {
        leverage = _leverage;
        adapter = ALMLeveragedPosition(leverage.implementation()).adapter();
    }

    function _approveIfNeeded(address token, address spender) internal {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            IERC20(token).forceApprove(spender, type(uint256).max);
        }
    }

    function mint(
        BaseALMAdapter.DepositParams memory depositParams,
        ALMLeveragedPosition.PositionInitParams memory initParams
    ) public returns (address position) {
        // If it's set to other address we will revert on safeTransfer, but update just in case
        depositParams.receiver = address(this);

        (address token0, address token1) = adapter.getVaultTokens(depositParams.vault);

        IERC20(token0).safeTransferFrom(msg.sender, address(this), depositParams.amount0Desired);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), depositParams.amount1Desired);

        _approveIfNeeded(token0, depositParams.vault);
        _approveIfNeeded(token1, depositParams.vault);

        (uint256 lpAmount, uint256 amount0Used, uint256 amount1Used) = adapter.delegateDeposit(depositParams);

        initParams.lpAmount = lpAmount;
        _approveIfNeeded(depositParams.vault, address(leverage));

        position = leverage.leverage(initParams);

        // Refund leftovers to user
        IERC20(token0).safeTransfer(msg.sender, depositParams.amount0Desired - amount0Used);
        IERC20(token1).safeTransfer(msg.sender, depositParams.amount1Desired - amount1Used);
    }
}
