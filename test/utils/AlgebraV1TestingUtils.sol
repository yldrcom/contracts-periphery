pragma solidity ^0.8.10;

import {BaseCLTestingUtils} from "./BaseCLTestingUtils.sol";
import {AlgebraV1Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/AlgebraV1Adapter.sol";
import {IAlgebraPool} from "@algebra/src/interfaces/IAlgebraPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract AlgebraV1TestingUtils is BaseCLTestingUtils, AlgebraV1Adapter {
    using SafeERC20 for IERC20;

    constructor(address _positionManager) AlgebraV1Adapter(_positionManager) {}

    function _movePoolPrice(address pool, uint160 targetSqrtPriceX96) internal virtual override {
        (uint160 sqrtPriceX96,) = _getPoolState(pool);

        if (sqrtPriceX96 > targetSqrtPriceX96) {
            IAlgebraPool(pool).swap(address(this), true, type(int256).max, targetSqrtPriceX96, "");
        } else {
            IAlgebraPool(pool).swap(address(this), false, type(int256).max, targetSqrtPriceX96, "");
        }
    }

    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        address token0 = IAlgebraPool(msg.sender).token0();
        address token1 = IAlgebraPool(msg.sender).token1();

        if (amount0Delta > 0) {
            deal(token0, address(this), uint256(amount0Delta));
            IERC20(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        } else {
            deal(token1, address(this), uint256(amount1Delta));
            IERC20(token1).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }
}
