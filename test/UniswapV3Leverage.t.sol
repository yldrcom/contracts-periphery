pragma solidity ^0.8.10;

import {PoolTesting} from "@yldr-lending/core/test/libraries/PoolTesting.sol";
import {UniswapV3Testing} from "@yldr-lending/core/test/libraries/UniswapV3Testing.sol";
import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ERC1155UniswapV3Wrapper} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155UniswapV3Wrapper.sol";
import {ERC1155UniswapV3ConfigurationProvider} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155UniswapV3ConfigurationProvider.sol";
import {ERC1155UniswapV3Oracle} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155UniswapV3Oracle.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UniswapV3Leverage, UniswapV3LeveragedPosition} from "../src/leverage/UniswapV3Leverage.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {AaveERC3156Wrapper, IPool as IAavePool} from "../src/flashloan/AaveERC3156Wrapper.sol";
import {AssetConverter, IAssetConverter} from "../src/AssetConverter.sol";
import {UniswapV3Converter, IQuoterV2} from "../src/converters/UniswapV3Converter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IYLDROracle, IPriceOracleGetter} from "@yldr-lending/core/src/interfaces/IYLDROracle.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

contract UniswapV3LeverageTest is BaseTest, IUniswapV3SwapCallback {
    using PoolTesting for PoolTesting.Data;
    using UniswapV3Testing for UniswapV3Testing.Data;
    using SafeERC20 for IERC20Metadata;

    IERC20Metadata usdc = IERC20Metadata(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Metadata weth = IERC20Metadata(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Metadata usdt = IERC20Metadata(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    PoolTesting.Data poolTesting;
    UniswapV3Testing.Data uniswapV3Testing;

    ERC1155UniswapV3Wrapper uniswapV3Wrapper;
    UniswapV3Leverage uniswapV3Leverage;

    AssetConverter assetConverter;
    UniswapV3Converter uniswapV3Converter;

    AaveERC3156Wrapper aaveFlashloan;

    constructor() {
        vm.createSelectFork("mainnet");
        vm.rollFork(18630167);

        _addAndDealToken(usdc);
        _addAndDealToken(weth);
        _addAndDealToken(usdt);

        uniswapV3Testing.init(INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));

        uniswapV3Wrapper = ERC1155UniswapV3Wrapper(
            address(
                new TransparentUpgradeableProxy(
                    address(new ERC1155UniswapV3Wrapper()),
                    ADMIN,
                    abi.encodeCall(ERC1155UniswapV3Wrapper.initialize, (uniswapV3Testing.positionManager))
                )
            )
        );

        vm.startPrank(ADMIN);
        poolTesting.init(ADMIN, 2);

        poolTesting.addReserve(
            address(usdc), 0.8e27, 0, 0.02e27, 0.8e27, 0.7e4, 0.75e4, 1.05e4, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6
        );
        poolTesting.addReserve(
            address(weth), 0.8e27, 0, 0.02e27, 0.8e27, 0.7e4, 0.75e4, 1.05e4, 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
        );

        poolTesting.addERC1155Reserve(
            address(uniswapV3Wrapper),
            address(
                new ERC1155UniswapV3ConfigurationProvider(
                    IPool(poolTesting.addressesProvider.getPool()), uniswapV3Wrapper
                )
            ),
            address(new ERC1155UniswapV3Oracle(poolTesting.addressesProvider, uniswapV3Wrapper))
        );

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

        uniswapV3Leverage = new UniswapV3Leverage(poolTesting.addressesProvider, uniswapV3Wrapper);

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

    function test_reverts_if_no_args() public {
        (uint256 tokenId,,) = uniswapV3Testing.acquireUniswapPosition(
            address(usdc), address(weth), 2000e6, 1e18, UniswapV3Testing.PositionType.Both
        );

        vm.expectRevert();
        uniswapV3Testing.positionManager.safeTransferFrom(ALICE, address(uniswapV3Leverage), tokenId, "");
    }

    function test_leverage() public {
        (uint256 tokenId,,) = uniswapV3Testing.acquireUniswapPosition(
            address(usdc), address(weth), 2000e6, 1e18, UniswapV3Testing.PositionType.Both
        );

        (,,,,,,, uint128 liquidityBefore,,,,) = uniswapV3Testing.positionManager.positions(tokenId);

        UniswapV3LeveragedPosition.PositionInitParams memory params = UniswapV3LeveragedPosition.PositionInitParams({
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

        address expectedPositionAddress = StdUtils.computeCreateAddress(address(uniswapV3Leverage), 2);

        UniswapV3LeveragedPosition(expectedPositionAddress).deleverage(
            aaveFlashloan,
            UniswapV3LeveragedPosition.DeleverageParams({
                assetConverter: assetConverter,
                receiver: ALICE,
                maxSwapSlippage: 50
            })
        );

        (,,,,,,, uint128 liquidityAfter,,,,) = uniswapV3Testing.positionManager.positions(tokenId);
        assertLt(liquidityAfter, liquidityBefore);
        assertApproxEqAbs(liquidityAfter, liquidityBefore, 0.01e18);
        assertEq(uniswapV3Testing.positionManager.ownerOf(tokenId), ALICE);
    }

    function _calculateSqrtPriceX96(uint256 token0Rate, uint256 token1Rate, uint8 token0Decimals, uint8 token1Decimals)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
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

    function test_leverage_liquidation() public {
        (uint256 tokenId,,) = uniswapV3Testing.acquireUniswapPosition(
            address(usdc), address(weth), 2000e6, 1e18, UniswapV3Testing.PositionType.Both
        );

        uniswapV3Testing.positionManager.positions(tokenId);

        UniswapV3LeveragedPosition.PositionInitParams memory params = UniswapV3LeveragedPosition.PositionInitParams({
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

        IYLDROracle oracle = IYLDROracle(poolTesting.addressesProvider.getPriceOracle());

        // Simulate price drop of ETH
        vm.mockCall(
            address(oracle), abi.encodeCall(IPriceOracleGetter.getAssetPrice, (address(weth))), abi.encode(550e8)
        );

        uint160 targetSqrtPrice =
            _calculateSqrtPriceX96(oracle.getAssetPrice(address(usdc)), oracle.getAssetPrice(address(weth)), 6, 18);
        vm.stopPrank();
        uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, targetSqrtPrice);

        address expectedPositionAddress = StdUtils.computeCreateAddress(address(uniswapV3Leverage), 2);

        IPool pool = IPool(poolTesting.addressesProvider.getPool());
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(expectedPositionAddress);

        assertLt(healthFactor, 1e18);

        vm.startPrank(BOB);

        pool.erc1155LiquidationCall(
            address(uniswapV3Wrapper), tokenId, address(usdc), expectedPositionAddress, 1000e6, false
        );
        pool.getUserAccountData(expectedPositionAddress);

        vm.startPrank(ALICE);
        UniswapV3LeveragedPosition(expectedPositionAddress).deleverage(
            aaveFlashloan,
            UniswapV3LeveragedPosition.DeleverageParams({
                assetConverter: assetConverter,
                receiver: ALICE,
                maxSwapSlippage: 50
            })
        );

        vm.startPrank(BOB);
        uint256 balance = uniswapV3Wrapper.balanceOf(BOB, tokenId);
        assertGt(balance, 0);
        uniswapV3Wrapper.burn(BOB, tokenId, balance, BOB);
    }

    function test_compound() public {
        (uint256 tokenId,,) = uniswapV3Testing.acquireUniswapPosition(
            address(usdc), address(weth), 2000e6, 1e18, UniswapV3Testing.PositionType.Both
        );

        (,,,,,,, uint128 liquidityBefore,,,,) = uniswapV3Testing.positionManager.positions(tokenId);

        UniswapV3LeveragedPosition.PositionInitParams memory params = UniswapV3LeveragedPosition.PositionInitParams({
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

        UniswapV3LeveragedPosition position =
            UniswapV3LeveragedPosition(StdUtils.computeCreateAddress(address(uniswapV3Leverage), 2));

        (uint160 currentSqrtPrice,,,,,,) = position.uniswapV3Pool().slot0();
        vm.stopPrank();
        // Do some movements to increase fees
        uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, currentSqrtPrice * 101 / 100);
        uniswapV3Testing.movePoolPrice(address(usdc), address(weth), 500, currentSqrtPrice);
        vm.startPrank(ALICE);

        position.compound(
            aaveFlashloan,
            UniswapV3LeveragedPosition.CompoundParams({assetConverter: assetConverter, maxSwapSlippage: 50})
        );

        (,,,,,,, uint128 liquidityAfter,,,,) = uniswapV3Testing.positionManager.positions(tokenId);
        assertGt(liquidityAfter, liquidityBefore);
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
}
