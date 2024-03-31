pragma solidity ^0.8.10;

import {PoolTesting, PoolConfigurator} from "@yldr-lending/core/test/libraries/PoolTesting.sol";
import {UniswapV3Testing} from "@yldr-lending/core/test/libraries/UniswapV3Testing.sol";
import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ERC1155UniswapV3Wrapper} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/erc1155-wrappers/ERC1155UniswapV3Wrapper.sol";
import {ERC1155CLWrapperOracle} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapperOracle.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {YLDRCLLeverage, BaseCLLeveragedPosition} from "../src/leverage/YLDRCLLeverage.sol";
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
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {YLDRFeeCollector} from "../src/YLDRFeeCollector.sol";
import {PercentageMath} from "@yldr-lending/core/src/protocol/libraries/math/PercentageMath.sol";
import {UniswapV3DataProvider} from "../src/ui/UniswapV3DataProvider.sol";
import {BaseCLLeveragedPosition} from "../src/leverage/position-impls/BaseCLLeveragedPosition.sol";
import {ERC1155CLWrapperConfigurationProvider} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapperConfigurationProvider.sol";
import {UniswapV3LeveragedPosition} from "../src/leverage/position-impls/UniswapV3LeveragedPosition.sol";

contract UniswapV3LeverageTest is BaseTest, IUniswapV3SwapCallback {
    using PoolTesting for PoolTesting.Data;
    using UniswapV3Testing for UniswapV3Testing.Data;
    using SafeERC20 for IERC20Metadata;
    using PercentageMath for uint256;

    IERC20Metadata usdc = IERC20Metadata(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Metadata weth = IERC20Metadata(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Metadata usdt = IERC20Metadata(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    PoolTesting.Data poolTesting;
    UniswapV3Testing.Data uniswapV3Testing;

    ERC1155UniswapV3Wrapper uniswapV3Wrapper;
    YLDRCLLeverage uniswapV3Leverage;

    AssetConverter assetConverter;
    UniswapV3Converter uniswapV3Converter;

    AaveERC3156Wrapper aaveFlashloan;
    YLDRERC3156Wrapper yldrFlashloan;
    CombinedERC3156Wrapper combinedFlashloan;

    YLDRFeeCollector feeCollector;

    UniswapV3DataProvider uniswapV3DataProvider;

    constructor() {
        vm.createSelectFork("mainnet");
        vm.rollFork(18630167);

        _addAndDealToken(usdc);
        _addAndDealToken(weth);
        _addAndDealToken(usdt);

        uniswapV3Testing.init(INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));
        uniswapV3DataProvider = new UniswapV3DataProvider(address(uniswapV3Testing.positionManager));

        uniswapV3Wrapper = ERC1155UniswapV3Wrapper(
            address(
                new TransparentUpgradeableProxy(
                    address(new ERC1155UniswapV3Wrapper(address(uniswapV3Testing.positionManager))),
                    ADMIN,
                    abi.encodeCall(ERC1155UniswapV3Wrapper.initialize, ())
                )
            )
        );

        feeCollector = new YLDRFeeCollector(uniswapV3Wrapper, ADMIN, ADMIN);

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
            0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6,
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
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419,
            0.15e4
        );

        poolTesting.addERC1155Reserve(
            address(uniswapV3Wrapper),
            address(
                new ERC1155CLWrapperConfigurationProvider(
                    IPool(poolTesting.addressesProvider.getPool()), uniswapV3Wrapper
                )
            ),
            address(new ERC1155CLWrapperOracle(poolTesting.addressesProvider, uniswapV3Wrapper)),
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

        aaveFlashloan = new AaveERC3156Wrapper(IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2));
        yldrFlashloan = new YLDRERC3156Wrapper(IPool(poolTesting.addressesProvider.getPool()));
        combinedFlashloan = new CombinedERC3156Wrapper(yldrFlashloan, aaveFlashloan, 0, address(this));

        UniswapV3LeveragedPosition implementation =
            new UniswapV3LeveragedPosition(poolTesting.addressesProvider, uniswapV3Wrapper, 1000, address(this));
        uniswapV3Leverage = new YLDRCLLeverage(implementation);

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
        BaseCLLeveragedPosition position;
    }

    function _aquireLeveragedPosition(uint256 amount0Desired, uint256 amount1Desired, uint256 amountToBorrow)
        internal
        returns (LeveragePositionData memory data)
    {
        (data.tokenId, data.amount0, data.amount1) = uniswapV3Testing.acquireUniswapPosition(
            address(usdc), address(weth), amount0Desired, amount1Desired, UniswapV3Testing.PositionType.Both
        );

        (,,,,,,, data.liquidityBeforeLeverage,,,,) = uniswapV3Testing.positionManager.positions(data.tokenId);

        uint64 nonce = vm.getNonce(address(uniswapV3Leverage));

        BaseCLLeveragedPosition.PositionInitParams memory params = BaseCLLeveragedPosition.PositionInitParams({
            tokenId: data.tokenId,
            tokenToBorrow: address(usdc),
            amountToBorrow: amountToBorrow,
            flashLoanProvider: aaveFlashloan,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        uint256 aliceNetWorthBefore = _getUsdValue(usdc.balanceOf(ALICE), weth.balanceOf(ALICE));

        uniswapV3Testing.positionManager.safeTransferFrom(
            ALICE, address(uniswapV3Leverage), data.tokenId, abi.encode(params)
        );

        uint256 aliceNetWorthAfter = _getUsdValue(usdc.balanceOf(ALICE), weth.balanceOf(ALICE));

        assertLt(
            aliceNetWorthAfter,
            aliceNetWorthBefore + _getUsdValue(data.amount0, data.amount1) / 1000,
            "Too much leftovers"
        );

        data.position = BaseCLLeveragedPosition(vm.computeCreateAddress(address(uniswapV3Leverage), nonce));

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
            IERC20(pool.getReserveData(address(usdc)).variableDebtTokenAddress).balanceOf(address(pos.position)), 0
        );

        UniswapV3DataProvider.CLPositionData memory positionData = uniswapV3DataProvider.getPositionData(pos.tokenId);

        uint256 balance = IERC1155(pool.getERC1155ReserveData(address(uniswapV3Wrapper)).nTokenAddress).balanceOf(
            address(pos.position), pos.tokenId
        );
        uint256 wrappedTotalSupply = uniswapV3Wrapper.totalSupply(pos.tokenId);

        withdrawLiquidity = withdrawLiquidity || balance != wrappedTotalSupply;

        uint256 positionValue = balance
            * _getUsdValue(positionData.amount0 + positionData.fee0, positionData.amount1 + positionData.fee1)
            / wrappedTotalSupply;

        (uint256 balance0Before, uint256 balance1Before) = (usdc.balanceOf(recipient), weth.balanceOf(recipient));

        pos.position.deleverage(
            flashloan,
            BaseCLLeveragedPosition.DeleverageParams({
                assetConverter: assetConverter,
                receiver: recipient,
                maxSwapSlippage: 50,
                withdrawLiquidity: withdrawLiquidity
            })
        );

        if (!withdrawLiquidity) {
            (,,,,,,, uint128 liquidityAfter,,,,) = uniswapV3Testing.positionManager.positions(pos.tokenId);
            assertLt(liquidityAfter, pos.liquidityBeforeLeverage);
            assertApproxEqAbs(liquidityAfter, pos.liquidityBeforeLeverage, 0.01e18);
            assertEq(uniswapV3Testing.positionManager.ownerOf(pos.tokenId), recipient);
        } else {
            (uint256 balance0After, uint256 balance1After) = (usdc.balanceOf(recipient), weth.balanceOf(recipient));
            uint256 usdIncrease = _getUsdValue(balance0After - balance0Before, balance1After - balance1Before);
            assertApproxEqRel(usdIncrease, positionValue - debtValue, 0.01e18);
        }

        assertEq(usdc.balanceOf(address(pos.position)), 0, "position has USDC after deleverage");
        assertEq(weth.balanceOf(address(pos.position)), 0, "position has WETH after deleverage");
    }

    function test_reverts_if_no_args() public {
        (uint256 tokenId,,) = uniswapV3Testing.acquireUniswapPosition(
            address(usdc), address(weth), 2000e6, 1e18, UniswapV3Testing.PositionType.Both
        );

        vm.expectRevert();
        uniswapV3Testing.positionManager.safeTransferFrom(ALICE, address(uniswapV3Leverage), tokenId, "");
    }

    function test_leverage() public {
        _genericWithdrawLiquidityTest(_test_leverage);
    }

    function _test_leverage(bool withdrawLiquidity) internal {
        LeveragePositionData memory pos = _aquireLeveragedPosition(2000e6, 1e18, 1000e6);
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

        LeveragePositionData memory pos = _aquireLeveragedPosition(2000e6, 1e18, 1000e6);

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

        LeveragePositionData memory pos = _aquireLeveragedPosition(2000e6, 1e18, 1000e6);

        uint256 usdcToTreasuryBefore = pool.getReserveData(address(usdc)).accruedToTreasury;
        _deleverage(pos, combinedFlashloan, ALICE, withdrawLiquidity);
        uint256 usdcToTreasuryAfter = pool.getReserveData(address(usdc)).accruedToTreasury;

        assertGt(usdcToTreasuryAfter, usdcToTreasuryBefore);
    }

    function test_leverage_liquidation() public {
        _genericWithdrawLiquidityTest(_test_leverage_liquidation);
    }

    function _test_leverage_liquidation(bool withdrawLiquidity) public {
        LeveragePositionData memory pos = _aquireLeveragedPosition(2000e6, 1e18, 1000e6);

        IPool pool = IPool(poolTesting.addressesProvider.getPool());
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());

        // Simulate price drop of ETH
        vm.mockCall(
            address(oracle), abi.encodeCall(IPriceOracleGetter.getAssetPrice, (address(weth))), abi.encode(550e8)
        );

        vm.stopPrank();
        uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, _calculateSqrtPriceX96());

        (,,,,, uint256 healthFactor) = pool.getUserAccountData(address(pos.position));

        assertLt(healthFactor, 1e18);

        vm.startPrank(BOB);

        uint256 adminBalanceBefore = weth.balanceOf(ADMIN);
        vm.expectCall(address(feeCollector), abi.encodePacked(YLDRFeeCollector.onERC1155Received.selector));
        pool.erc1155LiquidationCall(
            address(uniswapV3Wrapper), pos.tokenId, address(usdc), address(pos.position), 1000e6, false
        );
        assertGt(weth.balanceOf(ADMIN), adminBalanceBefore);

        pool.getUserAccountData(address(pos.position));

        vm.startPrank(ALICE);
        _deleverage(pos, aaveFlashloan, ALICE, withdrawLiquidity);

        vm.startPrank(BOB);
        uint256 balance = uniswapV3Wrapper.balanceOf(BOB, pos.tokenId);
        assertGt(balance, 0);
        uniswapV3Wrapper.burn(BOB, pos.tokenId, balance, BOB);

        vm.startPrank(ALICE);
    }

    function test_compound() public {
        (uint256 tokenId,,) = uniswapV3Testing.acquireUniswapPosition(
            address(usdc), address(weth), 2000e6, 1e18, UniswapV3Testing.PositionType.Both
        );

        (,,,,,,, uint128 liquidityBefore,,,,) = uniswapV3Testing.positionManager.positions(tokenId);

        BaseCLLeveragedPosition.PositionInitParams memory params = BaseCLLeveragedPosition.PositionInitParams({
            tokenId: tokenId,
            tokenToBorrow: address(usdc),
            amountToBorrow: 1000e6,
            flashLoanProvider: aaveFlashloan,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        uniswapV3Testing.positionManager.safeTransferFrom(
            ALICE, address(uniswapV3Leverage), tokenId, abi.encode(params)
        );

        BaseCLLeveragedPosition position =
            BaseCLLeveragedPosition(vm.computeCreateAddress(address(uniswapV3Leverage), 1));

        (uint160 currentSqrtPrice,,,,,,) = IUniswapV3Pool(position.liquidityPool()).slot0();
        vm.stopPrank();
        // Do some movements to increase fees
        uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, currentSqrtPrice * 101 / 100);
        uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, currentSqrtPrice);
        vm.startPrank(ALICE);

        position.compound(
            aaveFlashloan, BaseCLLeveragedPosition.CompoundParams({assetConverter: assetConverter, maxSwapSlippage: 50})
        );

        (,,,,,,, uint128 liquidityAfter,,,,) = uniswapV3Testing.positionManager.positions(tokenId);
        assertGt(liquidityAfter, liquidityBefore);
    }

    function test_deleverage_fees() public {
        (uint256 tokenId,,) = uniswapV3Testing.acquireUniswapPosition(
            address(usdc), address(weth), 2000e6, 1e18, UniswapV3Testing.PositionType.Both
        );

        BaseCLLeveragedPosition.PositionInitParams memory params = BaseCLLeveragedPosition.PositionInitParams({
            tokenId: tokenId,
            tokenToBorrow: address(usdc),
            amountToBorrow: 1000e6,
            flashLoanProvider: aaveFlashloan,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        uniswapV3Testing.positionManager.safeTransferFrom(
            ALICE, address(uniswapV3Leverage), tokenId, abi.encode(params)
        );

        BaseCLLeveragedPosition position =
            BaseCLLeveragedPosition(vm.computeCreateAddress(address(uniswapV3Leverage), 1));

        (uint160 currentSqrtPrice,,,,,,) = IUniswapV3Pool(position.liquidityPool()).slot0();
        vm.stopPrank();
        // Do some movements to increase fees
        uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, currentSqrtPrice * 101 / 100);
        uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, currentSqrtPrice);

        (uint256 lastFees0, uint256 lastFees1) = (position.lastFees0(), position.lastFees1());
        (uint256 fees0Before, uint256 fees1Before) = uniswapV3Wrapper.getPendingFees(tokenId);
        uint256 revenueFee = position.revenueFee();

        vm.startPrank(ALICE);
        position.deleverage(
            aaveFlashloan,
            BaseCLLeveragedPosition.DeleverageParams({
                assetConverter: assetConverter,
                receiver: ALICE,
                maxSwapSlippage: 50,
                withdrawLiquidity: false
            })
        );

        (,,,,,,,,,, uint128 tokensOwed0, uint128 tokensOwed1) = uniswapV3Testing.positionManager.positions(tokenId);

        assertEq(tokensOwed0, fees0Before - Math.mulDiv(fees0Before - lastFees0, revenueFee, 1e4));
        assertEq(tokensOwed1, fees1Before - Math.mulDiv(fees1Before - lastFees1, revenueFee, 1e4));
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

        (vars.tokenId, vars.amount0, vars.amount1) = uniswapV3Testing.acquireUniswapPosition(
            address(usdc), address(weth), 20000e6, 20e18, UniswapV3Testing.PositionType.Both
        );

        BaseCLLeveragedPosition.PositionInitParams memory params = BaseCLLeveragedPosition.PositionInitParams({
            tokenId: vars.tokenId,
            tokenToBorrow: address(usdc),
            amountToBorrow: vars.debtAmount,
            flashLoanProvider: aaveFlashloan,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });

        vars.positionValue = vars.amount0 * vars.oracle.getAssetPrice(address(usdc)) / 1e6
            + vars.amount1 * vars.oracle.getAssetPrice(address(weth)) / 1e18;
        vars.debtValue = vars.debtAmount * vars.oracle.getAssetPrice(address(usdc)) / 1e6;

        uint64 nonce = vm.getNonce(address(uniswapV3Leverage));
        uniswapV3Testing.positionManager.safeTransferFrom(
            ALICE, address(uniswapV3Leverage), vars.tokenId, abi.encode(params)
        );

        BaseCLLeveragedPosition position =
            BaseCLLeveragedPosition(vm.computeCreateAddress(address(uniswapV3Leverage), nonce));

        vars.revenueFee = 1000 * vars.debtValue / (vars.debtValue + vars.positionValue);
        assertApproxEqRel(position.revenueFee(), vars.revenueFee, 10 ** 16); // 1% delta allowed
        // Update so we have the actual value
        vars.revenueFee = position.revenueFee();

        (vars.currentSqrtPrice,,,,,,) = IUniswapV3Pool(position.liquidityPool()).slot0();
        vm.stopPrank();
        {
            (vars.fees0Before, vars.fees1Before) = uniswapV3Wrapper.getPendingFees(vars.tokenId);
            // Do some movements to increase fees
            uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, vars.currentSqrtPrice * 101 / 100);
            uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, vars.currentSqrtPrice);

            (vars.fees0After, vars.fees1After) = uniswapV3Wrapper.getPendingFees(vars.tokenId);
            (uint256 fees0ToTreasury, uint256 fees1ToTreasury) = (
                (vars.fees0After - vars.fees0Before) * vars.revenueFee / 1e4,
                (vars.fees1After - vars.fees1Before) * vars.revenueFee / 1e4
            );

            vm.expectCall(address(usdc), abi.encodeCall(IERC20.transfer, (address(this), fees0ToTreasury)));
            vm.expectCall(address(weth), abi.encodeCall(IERC20.transfer, (address(this), fees1ToTreasury)));
            vm.prank(ALICE);
            position.compound(
                aaveFlashloan,
                BaseCLLeveragedPosition.CompoundParams({assetConverter: assetConverter, maxSwapSlippage: 50})
            );
        }
        {
            (vars.fees0Before, vars.fees1Before) = uniswapV3Wrapper.getPendingFees(vars.tokenId);
            // Do some movements to increase fees
            uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, vars.currentSqrtPrice * 101 / 100);
            uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, vars.currentSqrtPrice);
            (vars.fees0After, vars.fees1After) = uniswapV3Wrapper.getPendingFees(vars.tokenId);
            (uint256 fees0ToTreasury, uint256 fees1ToTreasury) = (
                (vars.fees0After - vars.fees0Before) * vars.revenueFee / 1e4,
                (vars.fees1After - vars.fees1Before) * vars.revenueFee / 1e4
            );

            (uint256 treasury0Before, uint256 treasury1Before) =
                (usdc.balanceOf(address(this)), weth.balanceOf(address(this)));
            vm.prank(ALICE);
            position.deleverage(
                aaveFlashloan,
                BaseCLLeveragedPosition.DeleverageParams({
                    assetConverter: assetConverter,
                    receiver: ALICE,
                    maxSwapSlippage: 50,
                    withdrawLiquidity: withdrawLiquidity
                })
            );
            (uint256 treasury0After, uint256 treasury1After) =
                (usdc.balanceOf(address(this)), weth.balanceOf(address(this)));
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
        (uint256 tokenId,,) = uniswapV3Testing.acquireUniswapPosition(
            address(usdc), address(weth), 2000e6, 1e18, UniswapV3Testing.PositionType.Both
        );

        uint160 currentSqrtPrice = _calculateSqrtPriceX96();
        vm.stopPrank();
        uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, currentSqrtPrice * 10026 / 1e4);

        vm.prank(ALICE);
        BaseCLLeveragedPosition.PositionInitParams memory params = BaseCLLeveragedPosition.PositionInitParams({
            tokenId: tokenId,
            tokenToBorrow: address(usdc),
            amountToBorrow: 1000e6,
            flashLoanProvider: aaveFlashloan,
            assetConverter: assetConverter,
            owner: ALICE,
            maxSwapSlippage: 50
        });
        vm.expectRevert(BaseCLLeveragedPosition.TooBigPoolPriceDeviation.selector);
        uniswapV3Testing.positionManager.safeTransferFrom(
            ALICE, address(uniswapV3Leverage), tokenId, abi.encode(params)
        );

        uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, currentSqrtPrice * 10023 / 1e4);

        vm.prank(ALICE);
        uniswapV3Testing.positionManager.safeTransferFrom(
            ALICE, address(uniswapV3Leverage), tokenId, abi.encode(params)
        );
    }

    function _getUsdValue(uint256 usdcValue, uint256 wethValue) internal view returns (uint256) {
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());
        return usdcValue * oracle.getAssetPrice(address(usdc)) / 1e6
            + wethValue * oracle.getAssetPrice(address(weth)) / 1e18;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata /* data */ ) external {
        address token0 = IUniswapV3Pool(msg.sender).token0();
        address token1 = IUniswapV3Pool(msg.sender).token1();

        if (amount0Delta > 0) {
            IERC20Metadata(token0).safeTransfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            IERC20Metadata(token1).safeTransfer(msg.sender, uint256(amount1Delta));
        }
    }

    function _calculateSqrtPriceX96() internal view returns (uint160 sqrtPriceX96) {
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());

        uint256 token0Rate = oracle.getAssetPrice(address(usdc));
        uint256 token1Rate = oracle.getAssetPrice(address(weth));
        uint8 token0Decimals = 6;
        uint8 token1Decimals = 18;

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
        LeveragePositionData memory pos = _aquireLeveragedPosition(2000e6, 1e18, 1000e6);
        (,,,,, int24 tickLower, int24 tickUpper,,,,,) = uniswapV3Testing.positionManager.positions(pos.tokenId);

        uint256 positionValueBefore = _calculatePositionNetWorth(pos.position);

        pos.position.rebalance(
            aaveFlashloan,
            BaseCLLeveragedPosition.RebalanceParams({
                assetConverter: assetConverter,
                maxSwapSlippage: 50,
                newTickLower: tickUpper,
                newTickUpper: tickUpper + (tickUpper - tickLower)
            })
        );

        assertNotEq(pos.position.positionTokenId(), pos.tokenId);

        (,,,,, int24 newTickLower, int24 newTickUpper, uint128 newLiquidity,,,,) =
            uniswapV3Testing.positionManager.positions(pos.position.positionTokenId());

        assertEq(newTickLower, tickUpper);
        assertEq(newTickUpper, tickUpper + (tickUpper - tickLower));
        assertGt(newLiquidity, 0);

        uint256 positionValueAfter = _calculatePositionNetWorth(pos.position);
        assertApproxEqRel(positionValueAfter, positionValueBefore, 0.01e18);
    }

    function _calculatePositionNetWorth(BaseCLLeveragedPosition position) internal view returns (uint256) {
        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());
        IPool pool = IPool(poolTesting.addressesProvider.getPool());

        uint256 tokenId = position.positionTokenId();

        uint256 balance = IERC1155(pool.getERC1155ReserveData(address(uniswapV3Wrapper)).nTokenAddress).balanceOf(
            address(position), tokenId
        );
        uint256 wrappedTotalSupply = uniswapV3Wrapper.totalSupply(tokenId);

        UniswapV3DataProvider.CLPositionData memory positionData = uniswapV3DataProvider.getPositionData(tokenId);

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
}
