// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC1155UniswapV3Wrapper} from "@yldr-lending/core/src/interfaces/IERC1155UniswapV3Wrapper.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {UniswapV3Leverage, UniswapV3LeveragedPosition} from "./UniswapV3Leverage.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/// @author YLDR <admin@apyflow.com>
contract PositionManagerLeverageWrapper {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable factory;
    UniswapV3Leverage public immutable leverage;

    constructor(INonfungiblePositionManager _positionManager, UniswapV3Leverage _leverage) {
        positionManager = _positionManager;
        leverage = _leverage;
        factory = IUniswapV3Factory(_positionManager.factory());
    }

    function _approveIfNeeded(address token) internal {
        if (IERC20(token).allowance(address(this), address(positionManager)) == 0) {
            IERC20(token).forceApprove(address(positionManager), type(uint256).max);
        }
    }

    function mint(
        INonfungiblePositionManager.MintParams memory mintParams,
        UniswapV3LeveragedPosition.PositionInitParams memory initParams
    ) public {
        // If it's set to other address we will revert on safeTransfer, but update just in case
        mintParams.recipient = address(this);

        IERC20(mintParams.token0).safeTransferFrom(msg.sender, address(this), mintParams.amount0Desired);
        IERC20(mintParams.token1).safeTransferFrom(msg.sender, address(this), mintParams.amount1Desired);

        _approveIfNeeded(mintParams.token0);
        _approveIfNeeded(mintParams.token1);

        (uint256 tokenId,,uint256 amount0, uint256 amount1) = positionManager.mint(mintParams);

        initParams.tokenId = tokenId;
        positionManager.safeTransferFrom(address(this), address(leverage), initParams.tokenId, abi.encode(initParams));

        // Refund leftovers to user
        IERC20(mintParams.token0).safeTransfer(msg.sender, mintParams.amount0Desired - amount0);
        IERC20(mintParams.token1).safeTransfer(msg.sender, mintParams.amount1Desired - amount1);
    }
}
