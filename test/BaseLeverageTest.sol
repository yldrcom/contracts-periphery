pragma solidity ^0.8.10;

import {BaseCLAdapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/BaseCLAdapter.sol";
import {PoolTesting} from "@yldr-lending/core/test/libraries/PoolTesting.sol";
import {CLTesting, YLDRLeverageAutomations} from "./CLTesting.sol";
import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {ERC1155CLWrapperConfigurationProvider} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapperConfigurationProvider.sol";
import {ERC1155CLWrapperOracle} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapperOracle.sol";
import {CLDataProvider} from "../src/ui/CLDataProvider.sol";
import {YLDRCLLeverage} from "../src/leverage/YLDRCLLeverage.sol";
import {CLLeverageDataProvider} from "../src/ui/CLLeverageDataProvider.sol";
import {CLLeveragedPosition} from "../src/leverage/CLLeveragedPosition.sol";
import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {YLDRFeeCollector} from "../src/YLDRFeeCollector.sol";
import {BaseCLTestingUtils} from "./utils/BaseCLTestingUtils.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IYLDROracle, IPriceOracleGetter} from "@yldr-lending/core/src/interfaces/IYLDROracle.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AssetConverter} from "../src/AssetConverter.sol";
import {IPoolConfigurator} from "@yldr-lending/core/src/interfaces/IPoolConfigurator.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

abstract contract BaseLeverageTest is BaseTest {
    using CLTesting for CLTesting.Data;
    using PoolTesting for PoolTesting.Data;

    CLTesting.Data clTesting;
    PoolTesting.Data poolTesting;

    BaseCLTestingUtils testingUtils;
    IERC20Metadata token0;
    IERC20Metadata token1;
    IERC3156FlashLender flashloanProvider;
    AssetConverter assetConverter;

    struct SetupOutput {
        BaseCLAdapter adapter;
        BaseCLTestingUtils testingUtils;
        IERC3156FlashLender flashloanProvider;
        IERC20Metadata token0;
        IERC20Metadata token1;
        address token0Oracle;
        address token1Oracle;
    }

    function _setup() internal virtual returns (SetupOutput memory output);

    function _setupConverter(AssetConverter assetConverter) internal virtual;
    function _moveConverterPrice(uint160 sqrtPriceX96) internal virtual;

    constructor() {
        vm.startPrank(ADMIN);

        SetupOutput memory setup = _setup();

        testingUtils = setup.testingUtils;
        token0 = setup.token0;
        token1 = setup.token1;
        flashloanProvider = setup.flashloanProvider;

        _addAndDealToken(token0);
        _addAndDealToken(token1);

        poolTesting.init(ADMIN, 2);
        assetConverter = new AssetConverter(poolTesting.addressesProvider);

        clTesting.init(poolTesting, setup.adapter, assetConverter, flashloanProvider);

        poolTesting.addReserve(
            address(token0), 0.8e27, 0, 0.02e27, 0.8e27, 0.7e4, 0.75e4, 1.05e4, setup.token0Oracle, 0.15e4
        );
        poolTesting.addReserve(
            address(token1), 0.8e27, 0, 0.02e27, 0.8e27, 0.7e4, 0.75e4, 1.05e4, setup.token1Oracle, 0.15e4
        );

        IPoolConfigurator configurator = IPoolConfigurator(poolTesting.addressesProvider.getPoolConfigurator());
        configurator.setReserveFlashLoaning(address(token0), true);
        configurator.setReserveFlashLoaning(address(token1), true);
        configurator.updateFlashloanPremiumTotal(5);
        configurator.updateFlashloanPremiumToProtocol(5);

        _setupConverter(assetConverter);

        vm.startPrank(BOB);

        IPool pool = IPool(poolTesting.addressesProvider.getPool());
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);

        pool.supply(address(token0), _usdToToken(token0, 1_000_000e8), BOB, 0);
        pool.supply(address(token1), _usdToToken(token1, 1_000_000e8), BOB, 0);

        vm.stopPrank();
        vm.startPrank(ALICE);
    }

    struct LeveragePositionData {
        uint256 tokenId;
        uint256 amount0;
        uint256 amount1;
        uint128 liquidityBeforeLeverage;
        CLLeveragedPosition position;
    }

    function _aquireLeveragedPosition(uint256 amount0Desired, uint256 amount1Desired, uint256 amountToBorrow)
        internal
        returns (LeveragePositionData memory data)
    {
        (data.tokenId,, data.amount0, data.amount1) =
            testingUtils.mintPosition(address(token0), address(token1), amount0Desired, amount1Desired, ALICE);

        data.liquidityBeforeLeverage = clTesting.dataProvider.getPositionData(data.tokenId).liquidity;

        uint64 nonce = vm.getNonce(address(clTesting.leverage));

        CLLeveragedPosition.PositionInitParams memory params = CLLeveragedPosition.PositionInitParams({
            tokenId: data.tokenId,
            tokenToBorrow: address(token1),
            amountToBorrow: amountToBorrow,
            flashLoanProvider: flashloanProvider,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        uint256 aliceNetWorthBefore = _getUsdValue(token0.balanceOf(ALICE), token1.balanceOf(ALICE));

        clTesting.positionManager.safeTransferFrom(ALICE, address(clTesting.leverage), data.tokenId, abi.encode(params));

        uint256 aliceNetWorthAfter = _getUsdValue(token0.balanceOf(ALICE), token1.balanceOf(ALICE));

        assertLt(
            aliceNetWorthAfter,
            aliceNetWorthBefore + _getUsdValue(data.amount0, data.amount1) / 500,
            "Too much leftovers"
        );

        data.position = CLLeveragedPosition(vm.computeCreateAddress(address(clTesting.leverage), nonce));

        assertEq(token1.balanceOf(address(data.position)), 0, "position has token1 after creation");
        assertEq(token0.balanceOf(address(data.position)), 0, "position has token0 after creation");
    }

    function _deleverage(LeveragePositionData memory pos, address recipient, bool withdrawLiquidity) internal {
        IPool pool = IPool(poolTesting.addressesProvider.getPool());

        uint256 tokenId = pos.position.positionTokenId();

        uint256 debtValue = _getUsdValue(
            0,
            IERC20Metadata(pool.getReserveData(address(token1)).variableDebtTokenAddress).balanceOf(
                address(pos.position)
            )
        );

        CLDataProvider.CLPositionData memory positionData = clTesting.dataProvider.getPositionData(tokenId);

        uint256 balance = IERC1155(pool.getERC1155ReserveData(address(clTesting.wrapper)).nTokenAddress).balanceOf(
            address(pos.position), tokenId
        );
        uint256 wrappedTotalSupply = clTesting.wrapper.totalSupply(tokenId);

        withdrawLiquidity = withdrawLiquidity || balance != wrappedTotalSupply;

        uint256 positionValue = balance
            * _getUsdValue(positionData.amount0 + positionData.fee0, positionData.amount1 + positionData.fee1)
            / wrappedTotalSupply;

        (uint256 balance0Before, uint256 balance1Before) = (token0.balanceOf(recipient), token1.balanceOf(recipient));

        pos.position.deleverage(
            flashloanProvider,
            CLLeveragedPosition.DeleverageParams({
                assetConverter: assetConverter,
                receiver: recipient,
                maxSwapSlippage: 50,
                withdrawLiquidity: withdrawLiquidity
            })
        );

        if (!withdrawLiquidity) {
            // If no rebalance happened
            if (tokenId == pos.tokenId) {
                uint128 liquidityAfter = clTesting.dataProvider.getPositionData(pos.tokenId).liquidity;
                assertLt(liquidityAfter, pos.liquidityBeforeLeverage);
                assertApproxEqAbs(liquidityAfter, pos.liquidityBeforeLeverage, 0.01e18);
            }
            assertEq(clTesting.positionManager.ownerOf(tokenId), recipient);
        } else {
            (uint256 balance0After, uint256 balance1After) = (token0.balanceOf(recipient), token1.balanceOf(recipient));
            uint256 usdIncrease = _getUsdValue(balance0After - balance0Before, balance1After - balance1Before);
            assertApproxEqRel(usdIncrease, positionValue - debtValue, 0.01e18);
        }

        assertEq(token1.balanceOf(address(pos.position)), 0, "position has USDC after deleverage");
        assertEq(token0.balanceOf(address(pos.position)), 0, "position has WETH after deleverage");
    }

    function test_reverts_if_no_args() public {
        (uint256 tokenId,,,) = testingUtils.mintPosition(
            address(token0), address(token1), _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), ALICE
        );

        vm.expectRevert();
        clTesting.positionManager.safeTransferFrom(ALICE, address(clTesting.leverage), tokenId, "");
    }

    function test_leverage() public {
        _genericWithdrawLiquidityTest(_test_leverage);
    }

    function _test_leverage(bool withdrawLiquidity) internal {
        LeveragePositionData memory pos = _aquireLeveragedPosition(
            _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), _usdToToken(token1, 10_000e8)
        );
        _deleverage(pos, ALICE, withdrawLiquidity);
    }

    function test_leverage_combined_flash() public {
        _genericWithdrawLiquidityTest(_test_leverage_combined_flash);
    }

    function _test_leverage_combined_flash(bool withdrawLiquidity) public {
        IPool pool = IPool(poolTesting.addressesProvider.getPool());
        vm.stopPrank();

        vm.startPrank(ALICE);

        uint256 token1ToTreasuryBefore = pool.getReserveData(address(token1)).accruedToTreasury;
        LeveragePositionData memory pos = _aquireLeveragedPosition(
            _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), _usdToToken(token1, 10_000e8)
        );
        _deleverage(pos, ALICE, withdrawLiquidity);
        uint256 token1ToTreasuryAfter = pool.getReserveData(address(token1)).accruedToTreasury;

        assertGt(token1ToTreasuryAfter, token1ToTreasuryBefore);
    }

    function test_leverage_combined_flash_borrow_all() public {
        _genericWithdrawLiquidityTest(_test_leverage_combined_flash_borrow_all);
    }

    function _test_leverage_combined_flash_borrow_all(bool withdrawLiquidity) public {
        IPool pool = IPool(poolTesting.addressesProvider.getPool());
        vm.stopPrank();
        // leave only 1K in pool
        vm.startPrank(BOB);
        pool.withdraw(address(token1), 990_000e6, BOB);

        vm.startPrank(ALICE);

        uint256 token1ToTreasuryBefore = pool.getReserveData(address(token1)).accruedToTreasury;
        LeveragePositionData memory pos = _aquireLeveragedPosition(
            _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), _usdToToken(token1, 10_000e8)
        );
        _deleverage(pos, ALICE, withdrawLiquidity);
        uint256 token1ToTreasuryAfter = pool.getReserveData(address(token1)).accruedToTreasury;

        assertGt(token1ToTreasuryAfter, token1ToTreasuryBefore);
    }

    function test_leverage_liquidation() public {
        _genericWithdrawLiquidityTest(_test_leverage_liquidation);
    }

    function _test_leverage_liquidation(bool withdrawLiquidity) public {
        uint256 debt = _usdToToken(token1, 1000e6);
        LeveragePositionData memory pos =
            _aquireLeveragedPosition(_usdToToken(token0, 1000e6), _usdToToken(token1, 1000e6), debt);

        IPool pool = IPool(poolTesting.addressesProvider.getPool());
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());

        uint256 currentPrice = oracle.getAssetPrice(address(token0));

        // Simulate price drop of token0
        vm.mockCall(
            address(oracle),
            abi.encodeCall(IPriceOracleGetter.getAssetPrice, (address(token0))),
            abi.encode(currentPrice * 8 / 20)
        );

        vm.stopPrank();
        testingUtils.movePoolPrice(pos.tokenId, _calculateSqrtPriceX96());

        (,,,,, uint256 healthFactor) = pool.getUserAccountData(address(pos.position));

        assertLt(healthFactor, 1e18);

        vm.startPrank(BOB);

        uint256 adminBalanceBefore = token0.balanceOf(ADMIN);
        vm.expectCall(address(clTesting.feeCollector), abi.encodePacked(YLDRFeeCollector.onERC1155Received.selector));
        pool.erc1155LiquidationCall(
            address(clTesting.wrapper), pos.tokenId, address(token1), address(pos.position), debt, false
        );
        assertGt(token0.balanceOf(ADMIN), adminBalanceBefore);

        pool.getUserAccountData(address(pos.position));

        vm.startPrank(ALICE);
        _deleverage(pos, ALICE, withdrawLiquidity);

        vm.startPrank(BOB);
        uint256 balance = clTesting.wrapper.balanceOf(BOB, pos.tokenId);
        assertGt(balance, 0);
        clTesting.wrapper.burn(BOB, pos.tokenId, balance, BOB);

        vm.startPrank(ALICE);
    }

    function test_compound() public {
        (uint256 tokenId,,,) = testingUtils.mintPosition(
            address(token0), address(token1), _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), ALICE
        );

        uint128 liquidityBefore = clTesting.dataProvider.getPositionData(tokenId).liquidity;

        CLLeveragedPosition.PositionInitParams memory params = CLLeveragedPosition.PositionInitParams({
            tokenId: tokenId,
            tokenToBorrow: address(token1),
            amountToBorrow: _usdToToken(token1, 10_000e8),
            flashLoanProvider: flashloanProvider,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        clTesting.positionManager.safeTransferFrom(ALICE, address(clTesting.leverage), tokenId, abi.encode(params));

        CLLeveragedPosition position = CLLeveragedPosition(vm.computeCreateAddress(address(clTesting.leverage), 1));
        BaseCLAdapter.PositionData memory positionData = clTesting.adapter.getPositionData(tokenId);
        (uint160 currentSqrtPrice,) = clTesting.adapter.getPoolState(clTesting.adapter.getPool(positionData));
        vm.stopPrank();
        // Do some movements to increase fees
        testingUtils.movePoolPrice(tokenId, currentSqrtPrice * 101 / 100);
        testingUtils.movePoolPrice(tokenId, currentSqrtPrice);
        vm.startPrank(ALICE);

        position.compound(
            flashloanProvider, CLLeveragedPosition.CompoundParams({assetConverter: assetConverter, maxSwapSlippage: 50})
        );

        uint128 liquidityAfter = clTesting.dataProvider.getPositionData(tokenId).liquidity;
        assertGt(liquidityAfter, liquidityBefore);
    }

    function test_deleverage_fees() public {
        (uint256 tokenId,,,) = testingUtils.mintPosition(
            address(token0), address(token1), _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), ALICE
        );

        CLLeveragedPosition.PositionInitParams memory params = CLLeveragedPosition.PositionInitParams({
            tokenId: tokenId,
            tokenToBorrow: address(token1),
            amountToBorrow: _usdToToken(token1, 10_000e8),
            flashLoanProvider: flashloanProvider,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        clTesting.positionManager.safeTransferFrom(ALICE, address(clTesting.leverage), tokenId, abi.encode(params));

        CLLeveragedPosition position = CLLeveragedPosition(vm.computeCreateAddress(address(clTesting.leverage), 1));

        BaseCLAdapter.PositionData memory positionData = clTesting.adapter.getPositionData(tokenId);
        (uint160 currentSqrtPrice,) = clTesting.adapter.getPoolState(clTesting.adapter.getPool(positionData));
        vm.stopPrank();
        // Do some movements to increase fees
        testingUtils.movePoolPrice(tokenId, currentSqrtPrice * 101 / 100);
        testingUtils.movePoolPrice(tokenId, currentSqrtPrice);

        (uint256 lastFees0, uint256 lastFees1) = (position.lastFees0(), position.lastFees1());
        (uint256 fees0Before, uint256 fees1Before) = clTesting.adapter.getPendingFees(positionData);
        uint256 revenueFee = position.revenueFee();

        vm.startPrank(ALICE);
        position.deleverage(
            flashloanProvider,
            CLLeveragedPosition.DeleverageParams({
                assetConverter: assetConverter,
                receiver: ALICE,
                maxSwapSlippage: 50,
                withdrawLiquidity: false
            })
        );

        CLDataProvider.CLPositionData memory pos = clTesting.dataProvider.getPositionData(tokenId);

        assertGe(pos.fee0, fees0Before - Math.mulDiv(fees0Before - lastFees0, revenueFee, 1e4));
        assertGe(pos.fee1, fees1Before - Math.mulDiv(fees1Before - lastFees1, revenueFee, 1e4));
    }

    struct TestRevenueFeeVars {
        IYLDROracle oracle;
        uint256 debtAmount;
        uint256 tokenId;
        uint256 amount0;
        uint256 amount1;
        uint256 positionValue;
        uint256 debtValue;
        uint256 revenueFee;
        uint160 currentSqrtPrice;
        uint256 fees0Before;
        uint256 fees1Before;
        uint256 fees0After;
        uint256 fees1After;
    }

    function _testRevenueFee(bool withdrawLiquidity) public {
        TestRevenueFeeVars memory vars;

        vars.oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());

        vars.debtAmount = _usdToToken(token1, 10_000e8);

        (vars.tokenId,, vars.amount0, vars.amount1) = testingUtils.mintPosition(
            address(token0), address(token1), _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), ALICE
        );

        CLLeveragedPosition.PositionInitParams memory params = CLLeveragedPosition.PositionInitParams({
            tokenId: vars.tokenId,
            tokenToBorrow: address(token1),
            amountToBorrow: vars.debtAmount,
            flashLoanProvider: flashloanProvider,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        vars.positionValue = _getUsdValue(vars.amount0, vars.amount1);
        vars.debtValue = _getUsdValue(0, vars.debtAmount);

        uint64 nonce = vm.getNonce(address(clTesting.leverage));
        clTesting.positionManager.safeTransferFrom(ALICE, address(clTesting.leverage), vars.tokenId, abi.encode(params));

        CLLeveragedPosition position = CLLeveragedPosition(vm.computeCreateAddress(address(clTesting.leverage), nonce));

        vars.revenueFee = 1000 * vars.debtValue / (vars.debtValue + vars.positionValue);
        assertApproxEqRel(position.revenueFee(), vars.revenueFee, 10 ** 16); // 1% delta allowed
        // Update so we have the actual value
        vars.revenueFee = position.revenueFee();

        BaseCLAdapter.PositionData memory positionData = clTesting.adapter.getPositionData(vars.tokenId);
        (vars.currentSqrtPrice,) = clTesting.adapter.getPoolState(clTesting.adapter.getPool(positionData));
        vm.stopPrank();
        {
            (vars.fees0Before, vars.fees1Before) = _getPendingFees(vars.tokenId);
            // Do some movements to increase fees
            testingUtils.movePoolPrice(vars.tokenId, vars.currentSqrtPrice * 101 / 100);
            testingUtils.movePoolPrice(vars.tokenId, vars.currentSqrtPrice);

            (vars.fees0After, vars.fees1After) = _getPendingFees(vars.tokenId);
            (uint256 fees0ToTreasury, uint256 fees1ToTreasury) = (
                (vars.fees0After - vars.fees0Before) * vars.revenueFee / 1e4,
                (vars.fees1After - vars.fees1Before) * vars.revenueFee / 1e4
            );

            vm.expectCall(address(token0), abi.encodeCall(IERC20.transfer, (ADMIN, fees0ToTreasury)));
            vm.expectCall(address(token1), abi.encodeCall(IERC20.transfer, (ADMIN, fees1ToTreasury)));
            vm.prank(ALICE);
            position.compound(
                flashloanProvider,
                CLLeveragedPosition.CompoundParams({assetConverter: assetConverter, maxSwapSlippage: 50})
            );
        }
        {
            (vars.fees0Before, vars.fees1Before) = _getPendingFees(vars.tokenId);
            // Do some movements to increase fees
            testingUtils.movePoolPrice(vars.tokenId, vars.currentSqrtPrice * 101 / 100);
            testingUtils.movePoolPrice(vars.tokenId, vars.currentSqrtPrice);
            (vars.fees0After, vars.fees1After) = _getPendingFees(vars.tokenId);
            (uint256 fees0ToTreasury, uint256 fees1ToTreasury) = (
                (vars.fees0After - vars.fees0Before) * vars.revenueFee / 1e4,
                (vars.fees1After - vars.fees1Before) * vars.revenueFee / 1e4
            );

            (uint256 treasury0Before, uint256 treasury1Before) = (token0.balanceOf(ADMIN), token1.balanceOf(ADMIN));
            vm.prank(ALICE);
            position.deleverage(
                flashloanProvider,
                CLLeveragedPosition.DeleverageParams({
                    assetConverter: assetConverter,
                    receiver: ALICE,
                    maxSwapSlippage: 50,
                    withdrawLiquidity: withdrawLiquidity
                })
            );
            (uint256 treasury0After, uint256 treasury1After) = (token0.balanceOf(ADMIN), token1.balanceOf(ADMIN));
            uint256 usdFeeValue = _getUsdValue(fees0ToTreasury, fees1ToTreasury);
            uint256 usdValueIncrease = _getUsdValue(treasury0After - treasury0Before, treasury1After - treasury1Before);
            assertApproxEqRel(usdValueIncrease, usdFeeValue, 10 ** 16); // 1% delta allowed
        }
        vm.startPrank(ALICE);
    }

    function testRevenueFee() public {
        _genericWithdrawLiquidityTest(_testRevenueFee);
    }

    function test_pool_price_deviation_checked() external {
        (uint256 tokenId,,,) = testingUtils.mintPosition(
            address(token0), address(token1), _usdToToken(token0, 1000e8), _usdToToken(token1, 1000e8), ALICE
        );

        uint160 currentSqrtPrice = _calculateSqrtPriceX96();
        vm.stopPrank();
        testingUtils.movePoolPrice(tokenId, currentSqrtPrice * 10027 / 1e4);

        CLLeveragedPosition.PositionInitParams memory params = CLLeveragedPosition.PositionInitParams({
            tokenId: tokenId,
            tokenToBorrow: address(token1),
            amountToBorrow: _usdToToken(token1, 1000e8),
            flashLoanProvider: flashloanProvider,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });
        vm.prank(ALICE);
        vm.expectRevert(CLLeveragedPosition.TooBigPoolPriceDeviation.selector);
        clTesting.positionManager.safeTransferFrom(ALICE, address(clTesting.leverage), tokenId, abi.encode(params));

        testingUtils.movePoolPrice(tokenId, currentSqrtPrice * 10001 / 1e4);

        vm.prank(ALICE);
        clTesting.positionManager.safeTransferFrom(ALICE, address(clTesting.leverage), tokenId, abi.encode(params));
    }

    function _getUsdValue(uint256 token0Value, uint256 token1Value) internal view returns (uint256) {
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());
        return token1Value * oracle.getAssetPrice(address(token1)) / (10 ** token1.decimals())
            + token0Value * oracle.getAssetPrice(address(token0)) / (10 ** token0.decimals());
    }

    function _calculateSqrtPriceX96() internal view returns (uint160 sqrtPriceX96) {
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());

        uint256 token0Rate = oracle.getAssetPrice(address(token0));
        uint256 token1Rate = oracle.getAssetPrice(address(token1));

        // price = (10 ** token1Decimals) * token0Rate / ((10 ** token0Decimals) * token1Rate)
        // sqrtPriceX96 = sqrt(price * 2^192)

        // overflows only if token0 is 2**160 times more expensive than token1 (considered non-likely)
        uint256 factor1 = Math.mulDiv(token0Rate, 2 ** 96, token1Rate);

        // Cannot overflow if token1Decimals <= 18 and token0Decimals <= 18
        uint256 factor2 = Math.mulDiv(10 ** token1.decimals(), 2 ** 96, 10 ** token0.decimals());

        uint128 factor1Sqrt = uint128(Math.sqrt(factor1));
        uint128 factor2Sqrt = uint128(Math.sqrt(factor2));

        sqrtPriceX96 = factor1Sqrt * factor2Sqrt;
    }

    function _genericWithdrawLiquidityTest(function(bool) test) internal {
        uint256 snapshotId = vm.snapshot();
        test(true);
        vm.revertTo(snapshotId);
        vm.clearMockedCalls();
        test(false);
    }

    function test_rebalance() public {
        LeveragePositionData memory pos = _aquireLeveragedPosition(
            _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), _usdToToken(token1, 10_000e8)
        );
        CLDataProvider.CLPositionData memory posData = clTesting.dataProvider.getPositionData(pos.tokenId);

        uint256 positionValueBefore = _calculatePositionNetWorth(pos.position);

        pos.position.rebalance(
            flashloanProvider,
            CLLeveragedPosition.RebalanceParams({
                assetConverter: assetConverter,
                maxSwapSlippage: 50,
                newTickLower: posData.tickUpper,
                newTickUpper: posData.tickUpper + (posData.tickUpper - posData.tickLower)
            })
        );

        assertNotEq(pos.position.positionTokenId(), pos.tokenId);

        CLDataProvider.CLPositionData memory newPosData =
            clTesting.dataProvider.getPositionData(pos.position.positionTokenId());

        assertEq(newPosData.tickLower, posData.tickUpper);
        assertEq(newPosData.tickUpper, posData.tickUpper + (posData.tickUpper - posData.tickLower));
        assertGt(newPosData.liquidity, 0);

        uint256 positionValueAfter = _calculatePositionNetWorth(pos.position);
        assertApproxEqRel(positionValueAfter, positionValueBefore, 0.01e18);
    }

    function _calculateTokenUsdValue(uint256 tokenId) internal view returns (uint256) {
        CLDataProvider.CLPositionData memory positionData = clTesting.dataProvider.getPositionData(tokenId);
        return _getUsdValue(positionData.amount0 + positionData.fee0, positionData.amount1 + positionData.fee1);
    }

    function _calculatePositionNetWorth(CLLeveragedPosition position) internal view returns (uint256) {
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());
        IPool pool = IPool(poolTesting.addressesProvider.getPool());

        uint256 tokenId = position.positionTokenId();

        uint256 balance = IERC1155(pool.getERC1155ReserveData(address(clTesting.wrapper)).nTokenAddress).balanceOf(
            address(position), tokenId
        );
        uint256 wrappedTotalSupply = clTesting.wrapper.totalSupply(tokenId);

        uint256 positionValue = balance * _calculateTokenUsdValue(tokenId) / wrappedTotalSupply;

        address borrowedToken = position.borrowedToken();
        uint256 borrowedPrice = oracle.getAssetPrice(borrowedToken);

        uint256 debtAmount =
            IERC20Metadata(pool.getReserveData(borrowedToken).variableDebtTokenAddress).balanceOf(address(position));
        uint256 debtValue = borrowedPrice * debtAmount / (10 ** IERC20Metadata(borrowedToken).decimals());

        return positionValue - debtValue;
    }

    function _getPendingFees(uint256 tokenId) internal view returns (uint256, uint256) {
        BaseCLAdapter.PositionData memory positionData = clTesting.adapter.getPositionData(tokenId);
        return clTesting.adapter.getPendingFees(positionData);
    }

    function _usdToToken(IERC20Metadata token, uint256 usdValue) internal view returns (uint256) {
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());
        return usdValue * (10 ** token.decimals()) / oracle.getAssetPrice(address(token));
    }

    modifier noRevenueFee() {
        vm.stopPrank();
        vm.startPrank(ADMIN);
        clTesting.disableRevenueFee();
        vm.startPrank(ALICE);
        _;
    }

    function testAutomationsRebalance() public noRevenueFee {
        LeveragePositionData memory pos = _aquireLeveragedPosition(
            _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), _usdToToken(token1, 10_000e8)
        );
        BaseCLAdapter.PositionData memory posData = clTesting.adapter.getPositionData(pos.tokenId);

        YLDRLeverageAutomations.RecurringRebalanceConfig memory emptyParams;
        clTesting.leverageAutomations.setupRebalance(
            address(pos.position),
            posData.tickLower,
            posData.tickUpper,
            100,
            100,
            emptyParams,
            YLDRLeverageAutomations.GasFeeConfig({maxUsd: 1e8, maxPositionPercent: 0})
        );

        uint160 newSqrtPrice = TickMath.getSqrtRatioAtTick(posData.tickLower - 1);
        _movePrice(pos.tokenId, newSqrtPrice);

        uint256 alicePlusPositionBefore = _getNetWorth(ALICE) + _calculatePositionNetWorth(pos.position);
        uint256 adminUsdBefore = _getNetWorth(ADMIN);
        uint256 expectedFee =
            1e8 + clTesting.leverageAutomations.rebalanceFee() * _getPositionDebtValue(address(pos.position)) / 1e4;
        vm.startPrank(ADMIN);

        vm.expectRevert("Gas fee too high");
        clTesting.leverageAutomations.executeRebalance(address(pos.position), flashloanProvider, 1e8 + 1);

        clTesting.leverageAutomations.executeRebalance(address(pos.position), flashloanProvider, 1e8);

        uint256 alicePlusPositionAfter = _getNetWorth(ALICE) + _calculatePositionNetWorth(pos.position);
        assertApproxEqRel(_getNetWorth(ADMIN) - adminUsdBefore, expectedFee, 0.01e18);
        assertApproxEqRel(alicePlusPositionAfter, alicePlusPositionBefore - expectedFee, 0.01e18);

        (bool initialized,,,,,,) = clTesting.leverageAutomations.scheduledRebalances(address(pos.position));
        assertFalse(initialized);

        vm.startPrank(ALICE);

        uint256 newTokenId = pos.position.positionTokenId();

        _movePrice(pos.tokenId, newSqrtPrice);

        _deleverage(pos, ALICE, true);
        assertApproxEqRel(_getNetWorth(ALICE) + _calculateTokenUsdValue(newTokenId), alicePlusPositionAfter, 0.01e18);
    }

    function testAutomationsRebalanceRecurring() public noRevenueFee {
        LeveragePositionData memory pos = _aquireLeveragedPosition(
            _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), _usdToToken(token1, 10_000e8)
        );
        BaseCLAdapter.PositionData memory posData = clTesting.adapter.getPositionData(pos.tokenId);

        clTesting.leverageAutomations.setupRebalance(
            address(pos.position),
            posData.tickLower,
            posData.tickUpper,
            100,
            500,
            YLDRLeverageAutomations.RecurringRebalanceConfig({
                rangeConfig: YLDRLeverageAutomations.RangeConfig({
                    rangeConfigType: YLDRLeverageAutomations.RangeConfigType.TICKS,
                    ticksDown: 100,
                    ticksUp: 500,
                    sqrtPriceX96Down: 0,
                    sqrtPriceX96Up: 0
                }),
                endConfig: YLDRLeverageAutomations.EndConfig({
                    triggerType: YLDRLeverageAutomations.EndTriggerType.COUNT,
                    count: 5,
                    timestamp: 0
                }),
                active: true
            }),
            YLDRLeverageAutomations.GasFeeConfig({maxUsd: 0, maxPositionPercent: 1})
        );

        int24 tickSpacing = clTesting.adapter.getTickSpacing(clTesting.adapter.getPool(posData));
        uint256 cumulativeFeeUsd;

        for (uint256 i = 0; i < 5; i++) {
            (, int24 triggerLower, int24 triggerUpper,,,,) =
                clTesting.leverageAutomations.scheduledRebalances(address(pos.position));
            int24 newTick;
            if (i % 2 == 0) {
                newTick = triggerUpper + 1;
            } else {
                newTick = triggerLower - 1;
            }
            _movePrice(pos.tokenId, TickMath.getSqrtRatioAtTick(newTick));

            uint256 positionValueBefore = _calculatePositionNetWorth(pos.position);
            uint256 aliceBefore = _getNetWorth(ALICE);
            uint256 fee = positionValueBefore * 1 / 1e4;

            vm.startPrank(ADMIN);
            vm.expectRevert("Gas fee too high");
            clTesting.leverageAutomations.executeRebalance(address(pos.position), flashloanProvider, fee + 1);

            clTesting.leverageAutomations.executeRebalance(address(pos.position), flashloanProvider, fee);

            cumulativeFeeUsd += fee;

            uint256 positionAndAliceAfter = _calculatePositionNetWorth(pos.position) + _getNetWorth(ALICE);

            BaseCLAdapter.PositionData memory newPosData =
                clTesting.adapter.getPositionData(pos.position.positionTokenId());
            assertApproxEqAbs(newPosData.tickLower, newTick - 100, uint24(tickSpacing));
            assertApproxEqAbs(newPosData.tickUpper, newTick + 500, uint24(tickSpacing));

            assertApproxEqRel(positionAndAliceAfter, positionValueBefore + aliceBefore - fee, 0.01e18);
        }

        (bool initialized,,,,,,) = clTesting.leverageAutomations.scheduledRebalances(address(pos.position));
        assertFalse(initialized);
    }

    function testAutomationsCantIfNotEnabled() public noRevenueFee {
        LeveragePositionData memory pos = _aquireLeveragedPosition(
            _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), _usdToToken(token1, 10_000e8)
        );
        BaseCLAdapter.PositionData memory posData = clTesting.adapter.getPositionData(pos.tokenId);

        uint160 newSqrtPrice = TickMath.getSqrtRatioAtTick(posData.tickLower - 1);
        _movePrice(pos.tokenId, newSqrtPrice);

        vm.startPrank(ADMIN);
        vm.expectRevert("Rebalance not allowed");
        clTesting.leverageAutomations.executeRebalance(address(pos.position), flashloanProvider, 1e8);

        vm.expectRevert("Compound not allowed");
        clTesting.leverageAutomations.executeCompound(address(pos.position), flashloanProvider, 1e8);

        vm.expectRevert("Deleverage not allowed");
        clTesting.leverageAutomations.executeDeleverage(address(pos.position), flashloanProvider, 1e8);
    }

    function testAutomationsDeleverage() public noRevenueFee {
        LeveragePositionData memory pos = _aquireLeveragedPosition(
            _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), _usdToToken(token1, 10_000e8)
        );
        BaseCLAdapter.PositionData memory posData = clTesting.adapter.getPositionData(pos.tokenId);

        clTesting.leverageAutomations.setupDeleverage(
            address(pos.position),
            posData.tickLower,
            posData.tickUpper,
            false,
            YLDRLeverageAutomations.GasFeeConfig({maxUsd: 1e8, maxPositionPercent: 0})
        );

        uint160 newSqrtPrice = TickMath.getSqrtRatioAtTick(posData.tickLower - 1);
        _movePrice(pos.tokenId, newSqrtPrice);

        uint256 positionBefore = _calculatePositionNetWorth(pos.position);
        uint256 aliceBefore = _getNetWorth(ALICE);
        uint256 adminUsdBefore = _getNetWorth(ADMIN);
        uint256 expectedFee =
            1e8 + clTesting.leverageAutomations.deleverageFee() * _getPositionDebtValue(address(pos.position)) / 1e4;
        vm.startPrank(ADMIN);

        vm.expectRevert("Gas fee too high");
        clTesting.leverageAutomations.executeDeleverage(address(pos.position), flashloanProvider, 1e8 + 1);

        clTesting.leverageAutomations.executeDeleverage(address(pos.position), flashloanProvider, 1e8);

        uint256 aliceAfter = _getNetWorth(ALICE);
        uint256 adminUsdAfter = _getNetWorth(ADMIN);
        uint256 tokenValue = _calculateTokenUsdValue(pos.position.positionTokenId());

        assertEq(clTesting.positionManager.ownerOf(pos.tokenId), ALICE);
        assertApproxEqRel(adminUsdAfter - adminUsdBefore, expectedFee, 0.01e18);
        assertApproxEqRel(aliceAfter + tokenValue - aliceBefore, positionBefore - expectedFee, 0.01e18);

        (bool initialized,,,,) = clTesting.leverageAutomations.scheduledDeleverages(address(pos.position));
        assertFalse(initialized);
    }

    function testAutomationsCompound() public noRevenueFee {
        LeveragePositionData memory pos = _aquireLeveragedPosition(
            _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), _usdToToken(token1, 10_000e8)
        );
        BaseCLAdapter.PositionData memory posData = clTesting.adapter.getPositionData(pos.tokenId);

        clTesting.leverageAutomations.setupCompound(address(pos.position), 1000);

        (uint160 sqrtPriceX96,) = clTesting.adapter.getPoolState(clTesting.adapter.getPool(posData));

        // Move price to increase fees
        for (uint256 i = 0; i < 10; i++) {
            _movePrice(pos.tokenId, sqrtPriceX96 * 95 / 100);
            _movePrice(pos.tokenId, sqrtPriceX96);
        }

        vm.startPrank(ADMIN);
        clTesting.leverageAutomations.executeCompound(address(pos.position), flashloanProvider, 1e8);
    }

    function _movePrice(uint256 tokenId, uint160 sqrtPriceX96) internal {
        testingUtils.movePoolPrice(tokenId, sqrtPriceX96);
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());

        uint256 token1Rate = oracle.getAssetPrice(address(token1));

        // sqrtPriceX96 = sqrt((10 ** token1Decimals) * newToken0Rate / ((10 ** token0Decimals) * token1Rate) * 2^192)
        // sqrtPriceX96^2 = (10 ** token1Decimals) * newToken0Rate / ((10 ** token0Decimals) * token1Rate) * 2^192
        // newToken0Rate = sqrtPriceX96^2 * ((10 ** token0Decimals) * token1Rate) / (10 ** token1Decimals) / 2^192

        // factor1 = sqrtPriceX96 * (10 ** token0Decimals)
        // factor2 = sqrtPriceX96 * token1Rate / (10 ** token1Decimals)

        uint256 factor1 = sqrtPriceX96 * (10 ** token0.decimals());
        uint256 factor2 = sqrtPriceX96 * token1Rate / (10 ** token1.decimals());
        uint256 newToken0Rate = Math.mulDiv(factor1, factor2, 2 ** 192);

        vm.mockCall(
            address(oracle),
            abi.encodeCall(IPriceOracleGetter.getAssetPrice, (address(token0))),
            abi.encode(newToken0Rate)
        );

        _moveConverterPrice(sqrtPriceX96);
    }

    function _getNetWorth(address account) internal view returns (uint256) {
        return _getUsdValue(token0.balanceOf(account), token1.balanceOf(account));
    }

    function _getPositionDebtValue(address position) internal view returns (uint256) {
        IPool pool = IPool(poolTesting.addressesProvider.getPool());
        CLLeveragedPosition clPosition = CLLeveragedPosition(position);
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());
        uint256 debtAmount =
            IERC20Metadata(pool.getReserveData(clPosition.borrowedToken()).variableDebtTokenAddress).balanceOf(position);
        return oracle.getAssetPrice(clPosition.borrowedToken()) * debtAmount
            / (10 ** IERC20Metadata(clPosition.borrowedToken()).decimals());
    }

    function test_claimFees() public {
        LeveragePositionData memory pos = _aquireLeveragedPosition(
            _usdToToken(token0, 10_000e8), _usdToToken(token1, 10_000e8), _usdToToken(token1, 10_000e8)
        );

        BaseCLAdapter.PositionData memory positionData = clTesting.adapter.getPositionData(pos.tokenId);
        (uint160 currentSqrtPrice,) = clTesting.adapter.getPoolState(clTesting.adapter.getPool(positionData));
        vm.stopPrank();
        // Do some movements to increase fees
        testingUtils.movePoolPrice(pos.tokenId, currentSqrtPrice * 101 / 100);
        testingUtils.movePoolPrice(pos.tokenId, currentSqrtPrice);
        vm.startPrank(ALICE);

        uint128 liquidityBefore = clTesting.dataProvider.getPositionData(pos.tokenId).liquidity;
        uint256 balance0Before = token0.balanceOf(ALICE);
        uint256 balance1Before = token1.balanceOf(ALICE);


        pos.position.claimFees(
            flashloanProvider, CLLeveragedPosition.ClaimFeesParams({assetConverter: assetConverter, maxSwapSlippage: 50, withdrawFees: true})
        );

        uint128 liquidityAfter = clTesting.dataProvider.getPositionData(pos.tokenId).liquidity;
        assertEq(liquidityAfter, liquidityBefore);

        uint256 balance0After = token0.balanceOf(ALICE);
        uint256 balance1After = token1.balanceOf(ALICE);

        assertGt(balance0After, balance0Before);
        assertGt(balance1After, balance1Before);
    }
}
