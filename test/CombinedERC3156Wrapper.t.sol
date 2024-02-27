pragma solidity ^0.8.10;

import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {CombinedERC3156Wrapper} from "../src/flashloan/CombinedERC3156Wrapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {MockERC3156Wrapper, ERC20Mock} from "../src/mocks/MockERC3156Wrapper.sol";
import {PercentageMath} from "@yldr-lending/core/src/protocol/libraries/math/PercentageMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CombinedERC3156WrapperTest is BaseTest, IERC3156FlashBorrower {
    using SafeERC20 for ERC20Mock;
    using PercentageMath for uint256;

    ERC20Mock asset;

    constructor() {
        asset = new ERC20Mock("Asset", "ASSET", 18);
    }

    function testFuzz_fees(
        uint256 feeMain,
        uint256 feeFallback,
        uint256 minFee,
        uint256 maxMain,
        uint256 maxFallback,
        uint256 amountForTest
    ) public {
        feeMain = _bound(feeMain, 0, 10000);
        feeFallback = _bound(feeFallback, 0, 10000);
        minFee = _bound(minFee, 0, 10000);

        maxMain = _bound(maxMain, 0, 1_000_000_000 * 1e18);
        maxFallback = _bound(maxFallback, 0, 1_000_000_000 * 1e18);
        amountForTest = _bound(amountForTest, 0, maxMain + maxFallback);

        MockERC3156Wrapper main = new MockERC3156Wrapper(asset, feeMain);
        MockERC3156Wrapper fallback_ = new MockERC3156Wrapper(asset, feeFallback);

        asset.mint(address(main), maxMain);
        asset.mint(address(fallback_), maxFallback);

        CombinedERC3156Wrapper wrapper = new CombinedERC3156Wrapper(main, fallback_, minFee, BOB);

        uint256 feeMainExpected =
            (amountForTest > maxMain) ? maxMain.percentMul(feeMain) : amountForTest.percentMul(feeMain);
        uint256 feeFallbackExpected = (amountForTest > maxMain) ? (amountForTest - maxMain).percentMul(feeFallback) : 0;

        uint256 realFee = feeMainExpected + feeFallbackExpected;
        uint256 minFeeAmount = amountForTest.percentMul(minFee);

        uint256 feeToTreasuryExpected = (realFee < minFeeAmount) ? (minFeeAmount - realFee) : 0;

        wrapper.flashLoan(this, address(asset), amountForTest, "");

        assertEq(asset.balanceOf(address(main)), maxMain + feeMainExpected);
        assertEq(asset.balanceOf(address(fallback_)), maxFallback + feeFallbackExpected);
        assertEq(asset.balanceOf(BOB), feeToTreasuryExpected);
    }

    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata) external returns (bytes32) {
        deal(address(asset), address(this), amount + fee, false);
        asset.forceApprove(msg.sender, amount + fee);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
