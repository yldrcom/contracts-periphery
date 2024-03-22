// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC3156FlashLender, IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3FlashCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract UniswapV3ERC3156Wrapper is IERC3156FlashLender, IUniswapV3FlashCallback {
    using SafeERC20 for IERC20;

    IUniswapV3Pool public immutable pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint24 public immutable fee;

    struct CallbackData {
        IERC3156FlashBorrower receiver;
        address initiator;
        address token;
        uint256 amount;
        bytes data;
    }

    constructor(IUniswapV3Pool _pool) {
        pool = _pool;
        token0 = IERC20(_pool.token0());
        token1 = IERC20(_pool.token1());
        fee = _pool.fee();
    }

    /// @inheritdoc IERC3156FlashLender
    function maxFlashLoan(address token) external view override returns (uint256) {
        if (token != address(token0) && token != address(token1)) return 0;
        return IERC20(token).balanceOf(address(pool));
    }

    /// @inheritdoc IERC3156FlashLender
    function flashFee(address token, uint256 amount) external view override returns (uint256) {
        require(token == address(token0) || token == address(token1), "Token is not supported");
        return Math.mulDiv(amount, fee, 1e6, Math.Rounding.Ceil);
    }

    /// @inheritdoc IERC3156FlashLender
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata userData)
        external
        override
        returns (bool)
    {
        require(token == address(token0) || token == address(token1), "Token is not supported");

        bytes memory data = abi.encode(
            CallbackData({receiver: receiver, initiator: msg.sender, token: token, amount: amount, data: userData})
        );

        uint256 amount0 = token == address(token0) ? amount : 0;
        uint256 amount1 = token == address(token1) ? amount : 0;

        pool.flash(address(receiver), amount0, amount1, data);
        return true;
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external override {
        require(msg.sender == address(pool), "Only pool can call this function");

        CallbackData memory callbackData = abi.decode(data, (CallbackData));
        uint256 feeAmount = callbackData.token == address(token0) ? fee0 : fee1;

        require(
            callbackData.receiver.onFlashLoan(
                callbackData.initiator, callbackData.token, callbackData.amount, feeAmount, callbackData.data
            ) == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "IERC3156: Callback failed"
        );

        IERC20(callbackData.token).safeTransferFrom(
            address(callbackData.receiver), address(pool), callbackData.amount + feeAmount
        );
    }
}
