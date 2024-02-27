// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC3156FlashLender, IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IPool} from "@aave-v3/core/contracts/interfaces/IPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PercentageMath} from "@yldr-lending/core/src/protocol/libraries/math/PercentageMath.sol";

contract CombinedERC3156Wrapper is IERC3156FlashLender, IERC3156FlashBorrower {
    using PercentageMath for uint256;
    using SafeERC20 for IERC20;

    IERC3156FlashLender public immutable mainLender;
    IERC3156FlashLender public immutable fallbackLender;
    uint256 public immutable feePercent;
    address public immutable feeTreasury;

    /// @notice Common data for flashloan chain
    /// @param receiver - receiver of the starting flashloan
    /// @param data - data for the receiver
    /// @param amount - the total amount receiver requested
    struct CommonData {
        IERC3156FlashBorrower receiver;
        address initiator;
        bytes data;
        uint256 amount;
    }

    /// @notice Wrapper around `CommonData` for callback from main lender
    /// @param amountFromCallback - amount we need to request from fallback lender (0 if don't need any)
    struct MainCallbackData {
        CommonData commonData;
        uint256 amountFromFallback;
    }

    /// @notice Wrapper around `CommonData` for callback from fallback lender
    /// @param mainFee - fee that we need to pay to main lender
    struct FallbackCallbackData {
        CommonData commonData;
        uint256 mainFee;
    }

    constructor(
        IERC3156FlashLender _mainLender,
        IERC3156FlashLender _fallbackLender,
        uint256 _feePercent,
        address _feeTreasury
    ) {
        mainLender = _mainLender;
        fallbackLender = _fallbackLender;
        feePercent = _feePercent;
        feeTreasury = _feeTreasury;
    }

    /// @inheritdoc IERC3156FlashLender
    function maxFlashLoan(address token) external view override returns (uint256) {
        return mainLender.maxFlashLoan(token) + fallbackLender.maxFlashLoan(token);
    }

    /// @inheritdoc IERC3156FlashLender
    function flashFee(address token, uint256 amount) external view override returns (uint256) {
        uint256 maxMain = mainLender.maxFlashLoan(token);
        uint256 minFee = amount.percentMul(feePercent);
        if (amount <= maxMain) {
            return Math.max(minFee, mainLender.flashFee(token, amount));
        } else {
            return
                Math.max(minFee, mainLender.flashFee(token, maxMain) + fallbackLender.flashFee(token, amount - maxMain));
        }
    }

    /// @inheritdoc IERC3156FlashLender
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata userData)
        external
        override
        returns (bool)
    {
        uint256 maxMain = mainLender.maxFlashLoan(token);

        MainCallbackData memory callbackData = MainCallbackData({
            commonData: CommonData({receiver: receiver, initiator: msg.sender, data: userData, amount: amount}),
            amountFromFallback: amount > maxMain ? amount - maxMain : 0
        });

        bytes memory data = abi.encode(callbackData);
        mainLender.flashLoan(this, token, amount - callbackData.amountFromFallback, data);
        return true;
    }

    function _issueFlashloan(address token, CommonData memory commonData, uint256 totalFee) internal {
        uint256 minFee = commonData.amount.percentMul(feePercent);
        uint256 feeToTreasury = 0;
        if (totalFee < minFee) {
            feeToTreasury = minFee - totalFee;
            totalFee += feeToTreasury;
        }
        IERC20(token).safeTransfer(address(commonData.receiver), commonData.amount);
        require(
            commonData.receiver.onFlashLoan(commonData.initiator, token, commonData.amount, totalFee, commonData.data)
                == keccak256("ERC3156FlashBorrower.onFlashLoan"),
            "IERC3156: Callback failed"
        );
        IERC20(token).safeTransferFrom(address(commonData.receiver), address(this), commonData.amount + totalFee);
        if (feeToTreasury > 0) {
            IERC20(token).safeTransfer(feeTreasury, feeToTreasury);
        }
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata params)
        external
        returns (bytes32)
    {
        require(initiator == address(this), "Only this contract can initiate flash loan");

        if (msg.sender == address(mainLender)) {
            MainCallbackData memory data = abi.decode(params, (MainCallbackData));
            if (data.amountFromFallback > 0) {
                FallbackCallbackData memory callbackData =
                    FallbackCallbackData({commonData: data.commonData, mainFee: fee});
                fallbackLender.flashLoan(this, token, data.amountFromFallback, abi.encode(callbackData));
            } else {
                _issueFlashloan(token, data.commonData, fee);
            }
        } else if (msg.sender == address(fallbackLender)) {
            FallbackCallbackData memory data = abi.decode(params, (FallbackCallbackData));
            _issueFlashloan(token, data.commonData, data.mainFee + fee);
        } else {
            revert("Invalid provider");
        }

        IERC20(token).forceApprove(msg.sender, amount + fee);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
