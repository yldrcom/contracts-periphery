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
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {PositionManagerLeverageWrapper} from "../src/leverage/PositionManagerLeverageWrapper.sol";

contract PositionManagerLeverageWrapperTest is BaseTest {
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

    PositionManagerLeverageWrapper leverageWrapper;

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

        leverageWrapper = new PositionManagerLeverageWrapper(uniswapV3Testing.positionManager, uniswapV3Leverage);

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
        usdc.forceApprove(address(leverageWrapper), type(uint256).max);
        weth.forceApprove(address(leverageWrapper), type(uint256).max);

        IUniswapV3Pool pool = IUniswapV3Pool(uniswapV3Testing.factory.getPool(address(usdc), address(weth), 500));

        (, int24 tick,,,,,) = pool.slot0();
        int24 tickSpacing = int24(pool.tickSpacing());
        int24 tickLower = tick - 1000;
        int24 tickUpper = tick + 1000;

        tickLower -= tickLower % tickSpacing;
        tickUpper -= tickUpper % tickSpacing;

        leverageWrapper.mint(
            INonfungiblePositionManager.MintParams({
                token0: address(usdc),
                token1: address(weth),
                fee: 500,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: 1000 * (10 ** 6),
                amount1Desired: 10 ** 18,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: type(uint256).max
            }),
            UniswapV3LeveragedPosition.PositionInitParams({
                tokenId: 0,
                tokenToBorrow: address(usdc),
                amountToBorrow: 1000 * (10 ** 6),
                flashLoanProvider: aaveFlashloan,
                assetConverter: assetConverter,
                owner: ALICE,
                maxSwapSlippage: 50
            })
        );

        UniswapV3LeveragedPosition position =
            UniswapV3LeveragedPosition(StdUtils.computeCreateAddress(address(uniswapV3Leverage), 2));

        assertEq(position.owner(), ALICE);
    }
}
