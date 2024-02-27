// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC3156FlashLender, IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PercentageMath} from "@aave-v3/core/contracts/protocol/libraries/math/PercentageMath.sol";
import {ERC20Mock} from "@yldr-lending/core/src/mocks/ERC20Mock.sol";

contract MockERC3156Wrapper is IERC3156FlashLender {
    using SafeERC20 for ERC20Mock;
    using PercentageMath for uint256;

    ERC20Mock public immutable asset;
    uint256 public immutable fee;

    constructor(ERC20Mock _asset, uint256 _fee) {
        asset = _asset;
        fee = _fee;
    }

    /// @inheritdoc IERC3156FlashLender
    function maxFlashLoan(address token) external view override returns (uint256) {
        if (token != address(asset)) return 0;
        return asset.balanceOf(address(this));
    }

    /// @inheritdoc IERC3156FlashLender
    function flashFee(address token, uint256 amount) public view override returns (uint256) {
        require(token == address(asset), "Token is not supported");
        return amount.percentMul(fee);
    }

    /// @inheritdoc IERC3156FlashLender
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        require(token == address(asset), "Token is not supported");

        uint256 feeAmount = flashFee(token, amount);

        asset.safeTransfer(address(receiver), amount);
        require(
            receiver.onFlashLoan(msg.sender, address(asset), amount, feeAmount, data)
                == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "IERC3156: Callback failed"
        );
        asset.safeTransferFrom(address(receiver), address(this), amount + feeAmount);

        return true;
    }
}
