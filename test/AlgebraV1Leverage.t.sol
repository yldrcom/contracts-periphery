pragma solidity ^0.8.10;

import {PoolTesting, PoolConfigurator} from "@yldr-lending/core/test/libraries/PoolTesting.sol";
import {UniswapV3Testing} from "@yldr-lending/core/test/libraries/UniswapV3Testing.sol";
import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ERC1155CLWrapperOracle} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapperOracle.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20Metadata, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {AaveERC3156Wrapper, IPool as IAavePool} from "../src/flashloan/AaveERC3156Wrapper.sol";
import {YLDRERC3156Wrapper, IERC3156FlashLender} from "../src/flashloan/YLDRERC3156Wrapper.sol";
import {CombinedERC3156Wrapper} from "../src/flashloan/CombinedERC3156Wrapper.sol";
import {AssetConverter, IAssetConverter} from "../src/AssetConverter.sol";
import {UniswapV3Converter, IQuoterV2} from "../src/converters/UniswapV3Converter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IYLDROracle, IPriceOracleGetter} from "@yldr-lending/core/src/interfaces/IYLDROracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {IAlgebraPool} from "@algebra/src/interfaces/IAlgebraPool.sol";
import {YLDRFeeCollector} from "../src/YLDRFeeCollector.sol";
import {PercentageMath} from "@yldr-lending/core/src/protocol/libraries/math/PercentageMath.sol";
import {ERC1155CLWrapperConfigurationProvider} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapperConfigurationProvider.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {AlgebraV1TestingUtils} from "./utils/AlgebraV1TestingUtils.sol";
import {CLDataProvider} from "../src/ui/CLDataProvider.sol";
import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {YLDRCLLeverage} from "../src/leverage/YLDRCLLeverage.sol";
import {CLLeveragedPosition} from "../src/leverage/CLLeveragedPosition.sol";
import {BaseCLAdapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/BaseCLAdapter.sol";
import {AlgebraV1Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/AlgebraV1Adapter.sol";

contract AlgebraV1LeverageTest is BaseTest, IUniswapV3SwapCallback {
    using PoolTesting for PoolTesting.Data;
    using UniswapV3Testing for UniswapV3Testing.Data;
    using SafeERC20 for IERC20Metadata;
    using PercentageMath for uint256;

    IERC20Metadata usdc = IERC20Metadata(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20Metadata weth = IERC20Metadata(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20Metadata usdt = IERC20Metadata(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);

    PoolTesting.Data poolTesting;
    UniswapV3Testing.Data uniswapV3Testing;

    AlgebraV1TestingUtils algebraTesting;
    AlgebraV1Adapter algebraAdapter;
    ERC1155CLWrapper algebraWrapper;
    YLDRCLLeverage algebraLeverage;
    CLDataProvider algebraDataProvider;

    AssetConverter assetConverter;
    UniswapV3Converter uniswapV3Converter;

    AaveERC3156Wrapper aaveFlashloan;
    YLDRERC3156Wrapper yldrFlashloan;
    CombinedERC3156Wrapper combinedFlashloan;

    YLDRFeeCollector feeCollector;

    address camelotPositionManager = 0x00c7f3082833e796A5b3e4Bd59f6642FF44DCD15;

    constructor() {
        vm.createSelectFork("arbitrum_one");
        vm.rollFork(197388780);

        _addAndDealToken(usdc);
        _addAndDealToken(weth);
        _addAndDealToken(usdt);

        algebraTesting = new AlgebraV1TestingUtils(camelotPositionManager);

        uniswapV3Testing.init(INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));

        algebraAdapter = new AlgebraV1Adapter(camelotPositionManager);
        algebraDataProvider = new CLDataProvider(algebraAdapter);

        algebraWrapper = ERC1155CLWrapper(
            address(
                new TransparentUpgradeableProxy(
                    address(new ERC1155CLWrapper(algebraAdapter)),
                    ADMIN,
                    abi.encodeCall(ERC1155CLWrapper.initialize, ())
                )
            )
        );

        feeCollector = new YLDRFeeCollector(ADMIN, ADMIN);

        vm.startPrank(ADMIN);
        poolTesting.init(ADMIN, 2);

        poolTesting.addReserve(
            address(usdc),
            0.8e27,
            0,
            0.02e27,
            0.8e27,
            0.7e4,
            0.75e4,
            1.05e4,
            0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3,
            0.15e4
        );
        poolTesting.addReserve(
            address(weth),
            0.8e27,
            0,
            0.02e27,
            0.8e27,
            0.7e4,
            0.75e4,
            1.05e4,
            0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612,
            0.15e4
        );

        poolTesting.addERC1155Reserve(
            address(algebraWrapper),
            address(new ERC1155CLWrapperConfigurationProvider(poolTesting.addressesProvider, algebraWrapper)),
            address(new ERC1155CLWrapperOracle(poolTesting.addressesProvider, algebraWrapper)),
            address(feeCollector),
            0.2e4
        );

        PoolConfigurator configurator = PoolConfigurator(poolTesting.addressesProvider.getPoolConfigurator());
        configurator.setReserveFlashLoaning(address(usdc), true);
        configurator.setReserveFlashLoaning(address(weth), true);
        configurator.updateFlashloanPremiumTotal(5);
        configurator.updateFlashloanPremiumToProtocol(5);

        assetConverter = new AssetConverter(poolTesting.addressesProvider);
        uniswapV3Converter =
            new UniswapV3Converter(uniswapV3Testing.factory, IQuoterV2(0x61fFE014bA17989E743c5F6cB21bF9697530B21e));

        IAssetConverter.RouteConverterUpdate[] memory updates = new IAssetConverter.RouteConverterUpdate[](3);
        updates[0] = IAssetConverter.RouteConverterUpdate({
            source: address(usdc),
            destination: address(weth),
            converter: uniswapV3Converter
        });
        updates[1] = IAssetConverter.RouteConverterUpdate({
            source: address(weth),
            destination: address(usdc),
            converter: uniswapV3Converter
        });

        assetConverter.updateRoutes(updates);

        aaveFlashloan = new AaveERC3156Wrapper(IAavePool(0x794a61358D6845594F94dc1DB02A252b5b4814aD));
        yldrFlashloan = new YLDRERC3156Wrapper(IPool(poolTesting.addressesProvider.getPool()));
        combinedFlashloan = new CombinedERC3156Wrapper(yldrFlashloan, aaveFlashloan, address(this));

        CLLeveragedPosition implementation =
            new CLLeveragedPosition(poolTesting.addressesProvider, algebraWrapper, 1000, address(this), address(0));
        algebraLeverage = new YLDRCLLeverage(implementation, ADMIN);

        // Supply so the pool has funds for leverage operations
        vm.startPrank(BOB);
        IPool pool = IPool(poolTesting.addressesProvider.getPool());

        usdc.forceApprove(address(pool), type(uint256).max);
        weth.forceApprove(address(pool), type(uint256).max);
        usdt.forceApprove(address(pool), type(uint256).max);

        pool.supply(address(usdc), 1_000_000e6, BOB, 0);
        pool.supply(address(weth), 1_000e18, BOB, 0);

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
            algebraTesting.mintPosition(address(weth), address(usdc), amount0Desired, amount1Desired, ALICE);

        data.liquidityBeforeLeverage = algebraDataProvider.getPositionData(data.tokenId).liquidity;

        uint64 nonce = vm.getNonce(address(algebraLeverage));

        CLLeveragedPosition.PositionInitParams memory params = CLLeveragedPosition.PositionInitParams({
            tokenId: data.tokenId,
            tokenToBorrow: address(usdc),
            amountToBorrow: amountToBorrow,
            flashLoanProvider: aaveFlashloan,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        uint256 aliceNetWorthBefore = _getUsdValue(weth.balanceOf(ALICE), usdc.balanceOf(ALICE));

        IERC721(camelotPositionManager).safeTransferFrom(
            ALICE, address(algebraLeverage), data.tokenId, abi.encode(params)
        );

        uint256 aliceNetWorthAfter = _getUsdValue(weth.balanceOf(ALICE), usdc.balanceOf(ALICE));

        assertLt(
            aliceNetWorthAfter,
            aliceNetWorthBefore + _getUsdValue(data.amount0, data.amount1) / 1000,
            "Too much leftovers"
        );

        data.position = CLLeveragedPosition(vm.computeCreateAddress(address(algebraLeverage), nonce));

        assertEq(usdc.balanceOf(address(data.position)), 0, "position has USDC after creation");
        assertEq(weth.balanceOf(address(data.position)), 0, "position has WETH after creation");
    }

    function _deleverage(
        LeveragePositionData memory pos,
        IERC3156FlashLender flashloan,
        address recipient,
        bool withdrawLiquidity
    ) internal {
        IPool pool = IPool(poolTesting.addressesProvider.getPool());

        uint256 debtValue = _getUsdValue(
            0, IERC20(pool.getReserveData(address(usdc)).variableDebtTokenAddress).balanceOf(address(pos.position))
        );

        CLDataProvider.CLPositionData memory positionData = algebraDataProvider.getPositionData(pos.tokenId);

        uint256 balance = IERC1155(pool.getERC1155ReserveData(address(algebraWrapper)).nTokenAddress).balanceOf(
            address(pos.position), pos.tokenId
        );
        uint256 wrappedTotalSupply = algebraWrapper.totalSupply(pos.tokenId);

        withdrawLiquidity = withdrawLiquidity || balance != wrappedTotalSupply;

        uint256 positionValue = balance
            * _getUsdValue(positionData.amount0 + positionData.fee0, positionData.amount1 + positionData.fee1)
            / wrappedTotalSupply;

        (uint256 balance0Before, uint256 balance1Before) = (weth.balanceOf(recipient), usdc.balanceOf(recipient));

        pos.position.deleverage(
            flashloan,
            CLLeveragedPosition.DeleverageParams({
                assetConverter: assetConverter,
                receiver: recipient,
                maxSwapSlippage: 50,
                withdrawLiquidity: withdrawLiquidity
            })
        );

        if (!withdrawLiquidity) {
            uint128 liquidityAfter = algebraDataProvider.getPositionData(pos.tokenId).liquidity;
            assertLt(liquidityAfter, pos.liquidityBeforeLeverage);
            assertApproxEqAbs(liquidityAfter, pos.liquidityBeforeLeverage, 0.01e18);
            assertEq(IERC721(camelotPositionManager).ownerOf(pos.tokenId), recipient);
        } else {
            (uint256 balance0After, uint256 balance1After) = (weth.balanceOf(recipient), usdc.balanceOf(recipient));
            uint256 usdIncrease = _getUsdValue(balance0After - balance0Before, balance1After - balance1Before);
            assertApproxEqRel(usdIncrease, positionValue - debtValue, 0.01e18);
        }

        assertEq(usdc.balanceOf(address(pos.position)), 0, "position has USDC after deleverage");
        assertEq(weth.balanceOf(address(pos.position)), 0, "position has WETH after deleverage");
    }

    function test_reverts_if_no_args() public {
        (uint256 tokenId,,,) = algebraTesting.mintPosition(address(weth), address(usdc), 1e18, 2000e6, ALICE);

        vm.expectRevert();
        IERC721(camelotPositionManager).safeTransferFrom(ALICE, address(algebraLeverage), tokenId, "");
    }

    function test_leverage() public {
        _genericWithdrawLiquidityTest(_test_leverage);
    }

    function _test_leverage(bool withdrawLiquidity) internal {
        LeveragePositionData memory pos = _aquireLeveragedPosition(1e18, 2000e6, 1000e6);
        _deleverage(pos, aaveFlashloan, ALICE, withdrawLiquidity);
    }

    function test_leverage_combined_flash() public {
        _genericWithdrawLiquidityTest(_test_leverage_combined_flash);
    }

    function _test_leverage_combined_flash(bool withdrawLiquidity) public {
        IPool pool = IPool(poolTesting.addressesProvider.getPool());
        vm.stopPrank();
        // leave only 1.5K in pool
        vm.startPrank(BOB);
        pool.withdraw(address(usdc), 998_500e6, BOB);

        vm.startPrank(ALICE);

        LeveragePositionData memory pos = _aquireLeveragedPosition(1e18, 2000e6, 1000e6);

        uint256 usdcToTreasuryBefore = pool.getReserveData(address(usdc)).accruedToTreasury;
        _deleverage(pos, combinedFlashloan, ALICE, withdrawLiquidity);
        uint256 usdcToTreasuryAfter = pool.getReserveData(address(usdc)).accruedToTreasury;

        assertGt(usdcToTreasuryAfter, usdcToTreasuryBefore);
    }

    function test_leverage_combined_flash_borrow_all() public {
        _genericWithdrawLiquidityTest(_test_leverage_combined_flash_borrow_all);
    }

    function _test_leverage_combined_flash_borrow_all(bool withdrawLiquidity) public {
        IPool pool = IPool(poolTesting.addressesProvider.getPool());
        vm.stopPrank();
        // leave only 1K in pool
        vm.startPrank(BOB);
        pool.withdraw(address(usdc), 990_000e6, BOB);

        vm.startPrank(ALICE);

        LeveragePositionData memory pos = _aquireLeveragedPosition(1e18, 2000e6, 1000e6);

        uint256 usdcToTreasuryBefore = pool.getReserveData(address(usdc)).accruedToTreasury;
        _deleverage(pos, combinedFlashloan, ALICE, withdrawLiquidity);
        uint256 usdcToTreasuryAfter = pool.getReserveData(address(usdc)).accruedToTreasury;

        assertGt(usdcToTreasuryAfter, usdcToTreasuryBefore);
    }

    function test_leverage_liquidation() public {
        _genericWithdrawLiquidityTest(_test_leverage_liquidation);
    }

    function _test_leverage_liquidation(bool withdrawLiquidity) public {
        LeveragePositionData memory pos = _aquireLeveragedPosition(1e18, 2000e6, 1000e6);

        IPool pool = IPool(poolTesting.addressesProvider.getPool());
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());

        // Simulate price drop of ETH
        vm.mockCall(
            address(oracle), abi.encodeCall(IPriceOracleGetter.getAssetPrice, (address(weth))), abi.encode(800e8)
        );

        vm.stopPrank();
        algebraTesting.movePoolPrice(pos.tokenId, _calculateSqrtPriceX96());

        (,,,,, uint256 healthFactor) = pool.getUserAccountData(address(pos.position));

        assertLt(healthFactor, 1e18);

        vm.startPrank(BOB);

        uint256 adminBalanceBefore = weth.balanceOf(ADMIN);
        vm.expectCall(address(feeCollector), abi.encodePacked(YLDRFeeCollector.onERC1155Received.selector));
        pool.erc1155LiquidationCall(
            address(algebraWrapper), pos.tokenId, address(usdc), address(pos.position), 1000e6, false
        );
        assertGt(weth.balanceOf(ADMIN), adminBalanceBefore);

        pool.getUserAccountData(address(pos.position));

        vm.startPrank(ALICE);
        _deleverage(pos, aaveFlashloan, ALICE, withdrawLiquidity);

        vm.startPrank(BOB);
        uint256 balance = algebraWrapper.balanceOf(BOB, pos.tokenId);
        assertGt(balance, 0);
        algebraWrapper.burn(BOB, pos.tokenId, balance, BOB);

        vm.startPrank(ALICE);
    }

    function test_compound() public {
        (uint256 tokenId,,,) = algebraTesting.mintPosition(address(weth), address(usdc), 1e18, 2000e6, ALICE);

        uint128 liquidityBefore = algebraDataProvider.getPositionData(tokenId).liquidity;

        CLLeveragedPosition.PositionInitParams memory params = CLLeveragedPosition.PositionInitParams({
            tokenId: tokenId,
            tokenToBorrow: address(usdc),
            amountToBorrow: 1000e6,
            flashLoanProvider: aaveFlashloan,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        IERC721(camelotPositionManager).safeTransferFrom(ALICE, address(algebraLeverage), tokenId, abi.encode(params));

        CLLeveragedPosition position = CLLeveragedPosition(vm.computeCreateAddress(address(algebraLeverage), 1));
        BaseCLAdapter.PositionData memory positionData = algebraAdapter.getPositionData(tokenId);
        (uint160 currentSqrtPrice,) = algebraAdapter.getPoolState(algebraAdapter.getPool(positionData));
        vm.stopPrank();
        // Do some movements to increase fees
        algebraTesting.movePoolPrice(tokenId, currentSqrtPrice * 101 / 100);
        algebraTesting.movePoolPrice(tokenId, currentSqrtPrice);
        vm.startPrank(ALICE);

        position.compound(
            aaveFlashloan, CLLeveragedPosition.CompoundParams({assetConverter: assetConverter, maxSwapSlippage: 50})
        );

        uint128 liquidityAfter = algebraDataProvider.getPositionData(tokenId).liquidity;
        assertGt(liquidityAfter, liquidityBefore);
    }

    function test_deleverage_fees() public {
        (uint256 tokenId,,,) = algebraTesting.mintPosition(address(weth), address(usdc), 1e18, 2000e6, ALICE);

        CLLeveragedPosition.PositionInitParams memory params = CLLeveragedPosition.PositionInitParams({
            tokenId: tokenId,
            tokenToBorrow: address(usdc),
            amountToBorrow: 1000e6,
            flashLoanProvider: aaveFlashloan,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        IERC721(camelotPositionManager).safeTransferFrom(ALICE, address(algebraLeverage), tokenId, abi.encode(params));

        CLLeveragedPosition position = CLLeveragedPosition(vm.computeCreateAddress(address(algebraLeverage), 1));

        BaseCLAdapter.PositionData memory positionData = algebraAdapter.getPositionData(tokenId);
        (uint160 currentSqrtPrice,) = algebraAdapter.getPoolState(algebraAdapter.getPool(positionData));
        vm.stopPrank();
        // Do some movements to increase fees
        algebraTesting.movePoolPrice(tokenId, currentSqrtPrice * 101 / 100);
        algebraTesting.movePoolPrice(tokenId, currentSqrtPrice);

        (uint256 lastFees0, uint256 lastFees1) = (position.lastFees0(), position.lastFees1());
        (uint256 fees0Before, uint256 fees1Before) = algebraAdapter.getPendingFees(positionData);
        uint256 revenueFee = position.revenueFee();

        vm.startPrank(ALICE);
        position.deleverage(
            aaveFlashloan,
            CLLeveragedPosition.DeleverageParams({
                assetConverter: assetConverter,
                receiver: ALICE,
                maxSwapSlippage: 50,
                withdrawLiquidity: false
            })
        );

        CLDataProvider.CLPositionData memory pos = algebraDataProvider.getPositionData(tokenId);

        assertEq(pos.fee0, fees0Before - Math.mulDiv(fees0Before - lastFees0, revenueFee, 1e4));
        assertEq(pos.fee1, fees1Before - Math.mulDiv(fees1Before - lastFees1, revenueFee, 1e4));
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

        vars.debtAmount = 10000e6;

        (vars.tokenId,, vars.amount0, vars.amount1) =
            algebraTesting.mintPosition(address(weth), address(usdc), 20e18, 20000e6, ALICE);

        CLLeveragedPosition.PositionInitParams memory params = CLLeveragedPosition.PositionInitParams({
            tokenId: vars.tokenId,
            tokenToBorrow: address(usdc),
            amountToBorrow: vars.debtAmount,
            flashLoanProvider: aaveFlashloan,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        vars.positionValue = vars.amount1 * vars.oracle.getAssetPrice(address(usdc)) / 1e6
            + vars.amount0 * vars.oracle.getAssetPrice(address(weth)) / 1e18;
        vars.debtValue = vars.debtAmount * vars.oracle.getAssetPrice(address(usdc)) / 1e6;

        uint64 nonce = vm.getNonce(address(algebraLeverage));
        IERC721(camelotPositionManager).safeTransferFrom(
            ALICE, address(algebraLeverage), vars.tokenId, abi.encode(params)
        );

        CLLeveragedPosition position = CLLeveragedPosition(vm.computeCreateAddress(address(algebraLeverage), nonce));

        vars.revenueFee = 1000 * vars.debtValue / (vars.debtValue + vars.positionValue);
        assertApproxEqRel(position.revenueFee(), vars.revenueFee, 10 ** 16); // 1% delta allowed
        // Update so we have the actual value
        vars.revenueFee = position.revenueFee();

        BaseCLAdapter.PositionData memory positionData = algebraAdapter.getPositionData(vars.tokenId);
        (vars.currentSqrtPrice,) = algebraAdapter.getPoolState(algebraAdapter.getPool(positionData));
        vm.stopPrank();
        {
            (vars.fees0Before, vars.fees1Before) = _getPendingFees(vars.tokenId);
            // Do some movements to increase fees
            algebraTesting.movePoolPrice(vars.tokenId, vars.currentSqrtPrice * 101 / 100);
            algebraTesting.movePoolPrice(vars.tokenId, vars.currentSqrtPrice);

            (vars.fees0After, vars.fees1After) = _getPendingFees(vars.tokenId);
            (uint256 fees0ToTreasury, uint256 fees1ToTreasury) = (
                (vars.fees0After - vars.fees0Before) * vars.revenueFee / 1e4,
                (vars.fees1After - vars.fees1Before) * vars.revenueFee / 1e4
            );

            vm.expectCall(address(weth), abi.encodeCall(IERC20.transfer, (address(this), fees0ToTreasury)));
            vm.expectCall(address(usdc), abi.encodeCall(IERC20.transfer, (address(this), fees1ToTreasury)));
            vm.prank(ALICE);
            position.compound(
                aaveFlashloan, CLLeveragedPosition.CompoundParams({assetConverter: assetConverter, maxSwapSlippage: 50})
            );
        }
        {
            (vars.fees0Before, vars.fees1Before) = _getPendingFees(vars.tokenId);
            // Do some movements to increase fees
            algebraTesting.movePoolPrice(vars.tokenId, vars.currentSqrtPrice * 101 / 100);
            algebraTesting.movePoolPrice(vars.tokenId, vars.currentSqrtPrice);
            (vars.fees0After, vars.fees1After) = _getPendingFees(vars.tokenId);
            (uint256 fees0ToTreasury, uint256 fees1ToTreasury) = (
                (vars.fees0After - vars.fees0Before) * vars.revenueFee / 1e4,
                (vars.fees1After - vars.fees1Before) * vars.revenueFee / 1e4
            );

            (uint256 treasury0Before, uint256 treasury1Before) =
                (weth.balanceOf(address(this)), usdc.balanceOf(address(this)));
            vm.prank(ALICE);
            position.deleverage(
                aaveFlashloan,
                CLLeveragedPosition.DeleverageParams({
                    assetConverter: assetConverter,
                    receiver: ALICE,
                    maxSwapSlippage: 50,
                    withdrawLiquidity: withdrawLiquidity
                })
            );
            (uint256 treasury0After, uint256 treasury1After) =
                (weth.balanceOf(address(this)), usdc.balanceOf(address(this)));
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
        (uint256 tokenId,,,) = algebraTesting.mintPosition(address(weth), address(usdc), 1e18, 2000e6, ALICE);

        uint160 currentSqrtPrice = _calculateSqrtPriceX96();
        vm.stopPrank();
        algebraTesting.movePoolPrice(tokenId, currentSqrtPrice * 10027 / 1e4);

        vm.prank(ALICE);
        CLLeveragedPosition.PositionInitParams memory params = CLLeveragedPosition.PositionInitParams({
            tokenId: tokenId,
            tokenToBorrow: address(usdc),
            amountToBorrow: 1000e6,
            flashLoanProvider: aaveFlashloan,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });
        vm.expectRevert(CLLeveragedPosition.TooBigPoolPriceDeviation.selector);
        IERC721(camelotPositionManager).safeTransferFrom(ALICE, address(algebraLeverage), tokenId, abi.encode(params));

        algebraTesting.movePoolPrice(tokenId, currentSqrtPrice * 10023 / 1e4);

        vm.prank(ALICE);
        IERC721(camelotPositionManager).safeTransferFrom(ALICE, address(algebraLeverage), tokenId, abi.encode(params));
    }

    function _getUsdValue(uint256 wethValue, uint256 usdcValue) internal view returns (uint256) {
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());
        return usdcValue * oracle.getAssetPrice(address(usdc)) / 1e6
            + wethValue * oracle.getAssetPrice(address(weth)) / 1e18;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata /* data */ ) external {
        address token0 = IAlgebraPool(msg.sender).token0();
        address token1 = IAlgebraPool(msg.sender).token1();

        if (amount0Delta > 0) {
            IERC20Metadata(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            IERC20Metadata(token1).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }

    function _calculateSqrtPriceX96() internal view returns (uint160 sqrtPriceX96) {
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());

        uint256 token0Rate = oracle.getAssetPrice(address(weth));
        uint256 token1Rate = oracle.getAssetPrice(address(usdc));
        uint8 token0Decimals = 18;
        uint8 token1Decimals = 6;

        // price = (10 ** token1Decimals) * token0Rate / ((10 ** token0Decimals) * token1Rate)
        // sqrtPriceX96 = sqrt(price * 2^192)

        // overflows only if token0 is 2**160 times more expensive than token1 (considered non-likely)
        uint256 factor1 = Math.mulDiv(token0Rate, 2 ** 96, token1Rate);

        // Cannot overflow if token1Decimals <= 18 and token0Decimals <= 18
        uint256 factor2 = Math.mulDiv(10 ** token1Decimals, 2 ** 96, 10 ** token0Decimals);

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
        LeveragePositionData memory pos = _aquireLeveragedPosition(1e18, 2000e6, 1000e6);
        CLDataProvider.CLPositionData memory posData = algebraDataProvider.getPositionData(pos.tokenId);

        uint256 positionValueBefore = _calculatePositionNetWorth(pos.position);

        pos.position.rebalance(
            aaveFlashloan,
            CLLeveragedPosition.RebalanceParams({
                assetConverter: assetConverter,
                maxSwapSlippage: 50,
                newTickLower: posData.tickUpper,
                newTickUpper: posData.tickUpper + (posData.tickUpper - posData.tickLower)
            })
        );

        assertNotEq(pos.position.positionTokenId(), pos.tokenId);

        CLDataProvider.CLPositionData memory newPosData =
            algebraDataProvider.getPositionData(pos.position.positionTokenId());

        assertEq(newPosData.tickLower, posData.tickUpper);
        assertEq(newPosData.tickUpper, posData.tickUpper + (posData.tickUpper - posData.tickLower));
        assertGt(newPosData.liquidity, 0);

        uint256 positionValueAfter = _calculatePositionNetWorth(pos.position);
        assertApproxEqRel(positionValueAfter, positionValueBefore, 0.01e18);
    }

    function _calculatePositionNetWorth(CLLeveragedPosition position) internal view returns (uint256) {
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());
        IPool pool = IPool(poolTesting.addressesProvider.getPool());

        uint256 tokenId = position.positionTokenId();

        uint256 balance = IERC1155(pool.getERC1155ReserveData(address(algebraWrapper)).nTokenAddress).balanceOf(
            address(position), tokenId
        );
        uint256 wrappedTotalSupply = algebraWrapper.totalSupply(tokenId);

        CLDataProvider.CLPositionData memory positionData = algebraDataProvider.getPositionData(tokenId);

        uint256 positionValue = balance
            * _getUsdValue(positionData.amount0 + positionData.fee0, positionData.amount1 + positionData.fee1)
            / wrappedTotalSupply;

        address borrowedToken = position.borrowedToken();
        uint256 borrowedPrice = oracle.getAssetPrice(borrowedToken);

        uint256 debtAmount =
            IERC20(pool.getReserveData(borrowedToken).variableDebtTokenAddress).balanceOf(address(position));
        uint256 debtValue = borrowedPrice * debtAmount / (10 ** IERC20Metadata(borrowedToken).decimals());

        return positionValue - debtValue;
    }

    function _getPendingFees(uint256 tokenId) internal view returns (uint256, uint256) {
        BaseCLAdapter.PositionData memory positionData = algebraAdapter.getPositionData(tokenId);
        return algebraAdapter.getPendingFees(positionData);
    }
}
