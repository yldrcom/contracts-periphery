pragma solidity ^0.8.10;

import {IERC3156FlashLender, IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract BaseERC3156WrapperTest is BaseTest, IERC3156FlashBorrower {
    using SafeERC20 for IERC20Metadata;

    bytes expectedData;
    uint256 expectedBalanceAfter;
    uint256 expectedFee;
    address expectedToken;

    function _getAvailableTokens() internal virtual returns (address[] memory);
    function _getWrapper() internal virtual returns (IERC3156FlashLender);

    function _testWithAmount(address token, uint256 amount) internal {
        expectedData = hex"1234";
        expectedBalanceAfter = IERC20Metadata(token).balanceOf(address(this)) + amount;
        expectedFee = _getWrapper().flashFee(token, amount);
        expectedToken = token;

        _getWrapper().flashLoan(this, token, amount, expectedData);
    }

    function test() public {
        address[] memory tokens = _getAvailableTokens();

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 maxFlash = _getWrapper().maxFlashLoan(tokens[i]);

            _testWithAmount(tokens[i], maxFlash / 100);
            _testWithAmount(tokens[i], maxFlash / 10);
            _testWithAmount(tokens[i], maxFlash / 2);
            _testWithAmount(tokens[i], maxFlash * 3 / 4);
            _testWithAmount(tokens[i], maxFlash);
        }
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        assertEq(token, expectedToken, "token mismatch");
        assertEq(data, expectedData, "data mismatch");
        assertEq(IERC20Metadata(token).balanceOf(address(this)), expectedBalanceAfter, "balance mismatch");
        assertEq(fee, expectedFee, "fee mismatch");

        deal(token, address(this), amount + fee, false);
        IERC20Metadata(token).forceApprove(msg.sender, amount + fee);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
