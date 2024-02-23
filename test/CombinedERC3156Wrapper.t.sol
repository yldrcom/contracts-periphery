pragma solidity ^0.8.10;

import {PoolTesting, PoolConfigurator} from "@yldr-lending/core/test/libraries/PoolTesting.sol";
import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {AaveERC3156Wrapper, IPool as IAavePool} from "../src/flashloan/AaveERC3156Wrapper.sol";
import {YLDRERC3156Wrapper} from "../src/flashloan/YLDRERC3156Wrapper.sol";
import {CombinedERC3156Wrapper} from "../src/flashloan/CombinedERC3156Wrapper.sol";
import {AssetConverter, IAssetConverter} from "../src/AssetConverter.sol";
import {UniswapV3Converter, IQuoterV2} from "../src/converters/UniswapV3Converter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYLDROracle, IPriceOracleGetter} from "@yldr-lending/core/src/interfaces/IYLDROracle.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";

contract CombinedERC3156WrapperTest is BaseTest, IERC3156FlashBorrower {
    using PoolTesting for PoolTesting.Data;
    using SafeERC20 for IERC20Metadata;

    IERC20Metadata usdc = IERC20Metadata(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    PoolTesting.Data poolTesting;

    AaveERC3156Wrapper aaveFlashloan;
    YLDRERC3156Wrapper yldrFlashloan;
    CombinedERC3156Wrapper combinedFlashloan;

    IPool yldrPool;
    IAavePool aavePool;

    constructor() {
        vm.createSelectFork("mainnet");
        vm.rollFork(18630167);

        _addAndDealToken(usdc);

        vm.startPrank(ADMIN);
        poolTesting.init(ADMIN, 2);

        poolTesting.addReserve(
            address(usdc), 0.8e27, 0, 0.02e27, 0.8e27, 0.7e4, 0.75e4, 1.05e4, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6
        );

        PoolConfigurator configurator = PoolConfigurator(poolTesting.addressesProvider.getPoolConfigurator());

        configurator.setReserveFlashLoaning(address(usdc), true);
        configurator.updateFlashloanPremiumTotal(5);
        configurator.updateFlashloanPremiumToProtocol(5);

        yldrPool = IPool(poolTesting.addressesProvider.getPool());
        aavePool = IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);

        yldrFlashloan = new YLDRERC3156Wrapper(yldrPool);
        aaveFlashloan = new AaveERC3156Wrapper(aavePool);
        combinedFlashloan = new CombinedERC3156Wrapper(yldrFlashloan, aaveFlashloan);

        // Supply so the pool has funds for flashloan operations
        vm.startPrank(BOB);
        usdc.forceApprove(address(yldrPool), type(uint256).max);
        yldrPool.supply(address(usdc), 1_000e6, BOB, 0);

        vm.startPrank(ALICE);
    }

    bytes expectedData;
    uint256 expectedBalanceAfter;
    uint256 expectedYLDRBalanceAfter;
    uint256 expectedAaveBalanceAfter;

    function _getYLDRBalance() internal view returns (uint256) {
        return usdc.balanceOf(yldrPool.getReserveData(address(usdc)).yTokenAddress);
    }

    function _getAaveBalance() internal view returns (uint256) {
        return usdc.balanceOf(aavePool.getReserveData(address(usdc)).aTokenAddress);
    }

    function _testWithAmount(uint256 amount) internal {
        expectedData = hex"1234";
        expectedBalanceAfter = usdc.balanceOf(address(this)) + amount;

        uint256 curYldrBalance = _getYLDRBalance();
        uint256 curAaveBalance = _getAaveBalance();

        if (curYldrBalance >= amount) {
            expectedYLDRBalanceAfter = curYldrBalance - amount;
            expectedAaveBalanceAfter = curAaveBalance;
        } else {
            expectedYLDRBalanceAfter = 0;
            expectedAaveBalanceAfter = curAaveBalance - (amount - curYldrBalance);
        }

        combinedFlashloan.flashLoan(this, address(usdc), amount, expectedData);
    }

    function test_can_flashloan() public {
        _testWithAmount(100e6);
        _testWithAmount(300e6);
        _testWithAmount(700e6);
        _testWithAmount(1000e6);
        _testWithAmount(10_000e6);
        _testWithAmount(1_000_000e6);
    }

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        returns (bytes32)
    {
        assertEq(token, address(usdc));
        assertEq(data, expectedData);
        assertEq(usdc.balanceOf(address(this)), expectedBalanceAfter);
        assertEq(_getYLDRBalance(), expectedYLDRBalanceAfter);
        assertEq(_getAaveBalance(), expectedAaveBalanceAfter);
        assertEq(initiator, ALICE);

        usdc.forceApprove(msg.sender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
