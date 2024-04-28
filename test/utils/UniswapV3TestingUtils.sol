pragma solidity ^0.8.10;

import {BaseCLTestingUtils} from "./BaseCLTestingUtils.sol";
import {UniswapV3Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/UniswapV3Adapter.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract UniswapV3TestingUtils is BaseCLTestingUtils {
    using SafeERC20 for IERC20;

    constructor(UniswapV3Adapter _adapter) BaseCLTestingUtils(_adapter) {}

    function _movePoolPrice(address pool, uint160 targetSqrtPriceX96) internal virtual override {
        (uint160 sqrtPriceX96,) = adapter.getPoolState(pool);

        if (sqrtPriceX96 == targetSqrtPriceX96) {
            return;
        }

        if (sqrtPriceX96 > targetSqrtPriceX96) {
            IUniswapV3Pool(pool).swap(address(this), true, type(int256).max, targetSqrtPriceX96, "");
        } else {
            IUniswapV3Pool(pool).swap(address(this), false, type(int256).max, targetSqrtPriceX96, "");
        }
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        address token0 = IUniswapV3Pool(msg.sender).token0();
        address token1 = IUniswapV3Pool(msg.sender).token1();

        if (amount0Delta > 0) {
            deal(token0, address(this), uint256(amount0Delta));
            IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        } else {
            deal(token1, address(this), uint256(amount1Delta));
            IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }
}
