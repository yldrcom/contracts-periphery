pragma solidity ^0.8.10;

import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {SteerLeveragedPosition, BaseERC20LeveragedPosition} from "../src/SteerLeveragedPosition.sol";
import {PoolTesting, IPool} from "@yldr-lending/core/test/libraries/PoolTesting.sol";
import {ISteerVault} from "@yldr-lending/core/src/interfaces/ext/ISteerVault.sol";
import {ERC20Leverage} from "../src/ERC20Leverage.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SteerVaultOracle} from "@yldr-lending/core/src/integrations/steer/SteerVaultOracle.sol";
import {AlgebraV1Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/AlgebraV1Adapter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAssetConverter} from "../src/interfaces/IAssetConverter.sol";
import {UniswapV3Converter, IQuoterV2, IUniswapV3Factory} from "../src/converters/UniswapV3Converter.sol";
import {AssetConverter} from "../src/AssetConverter.sol";
import {YLDRERC3156Wrapper} from "../src/flashloan/YLDRERC3156Wrapper.sol";
import {SteerStrategy} from "../src/SteerStrategy.sol";

contract SteerStrategyTest is BaseTest {
    using PoolTesting for PoolTesting.Data;
    using SafeERC20 for IERC20Metadata;

    PoolTesting.Data poolTesting;

    ISteerVault steerVault = ISteerVault(0x7b99506C8E89D5ba835e00E2bC48e118264d44ff);

    IERC20Metadata usdc = IERC20Metadata(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359);
    IERC20Metadata weth = IERC20Metadata(0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619);

    AssetConverter assetConverter;

    YLDRERC3156Wrapper flashloanProvider;

    SteerStrategy vault;

    constructor() {
        vm.createSelectFork("polygon");
        vm.rollFork(58293571);

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
            0xfE4A8cc5b5B2366C1B58Bea3858e81843581b2F7,
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
            0xF9680D99D6C9589e2a93a78A04A279e509205945,
            0.15e4
        );
        AlgebraV1Adapter adapter = new AlgebraV1Adapter(0x8eF88E4c7CfbbaC1C163f7eddd4B578792201de6, false);
        poolTesting.addReserve(
            address(steerVault),
            0.8e27,
            0,
            0.02e27,
            0.8e27,
            0.7e4,
            0.75e4,
            1.05e4,
            address(new SteerVaultOracle(steerVault, adapter, poolTesting.addressesProvider)),
            0.15e4
        );

        assetConverter = new AssetConverter(poolTesting.addressesProvider);
        UniswapV3Converter uniswapV3Converter = new UniswapV3Converter(
            IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984),
            IQuoterV2(0x61fFE014bA17989E743c5F6cB21bF9697530B21e)
        );

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

        IPool pool = IPool(poolTesting.addressesProvider.getPool());
        flashloanProvider = new YLDRERC3156Wrapper(pool);

        vault = new SteerStrategy(
            "Steer strategy", "STEER", usdc, steerVault, poolTesting.addressesProvider, assetConverter
        );

        vm.startPrank(BOB);

        deal(address(usdc), BOB, 1_000_000e6);
        deal(address(weth), BOB, 1_000e18);

        usdc.forceApprove(address(pool), 1_000_000e6);
        weth.forceApprove(address(pool), 1_000e18);

        pool.supply(address(usdc), 1_000_000e6, BOB, 0);
        pool.supply(address(weth), 1_000e18, BOB, 0);

        vm.startPrank(ALICE);

        deal(address(usdc), ALICE, 1000e6);
        deal(address(weth), ALICE, 1e18);

        usdc.forceApprove(address(vault), 1000e6);
    }

    function test() public {
        uint256 usdcBalanceBefore = usdc.balanceOf(ALICE);
        uint256 wethBalanceBefore = weth.balanceOf(ALICE);

        uint256 shares = vault.deposit(1000e6);

        uint256 assets = vault.redeem(shares);

        uint256 usdcBalanceAfter = usdc.balanceOf(ALICE);
        uint256 wethBalanceAfter = weth.balanceOf(ALICE);

        assertApproxEqAbs(usdcBalanceAfter, usdcBalanceBefore, 1000e6 / 100);
        assertApproxEqAbs(wethBalanceAfter, wethBalanceBefore, 1e18 / 100);
    }
}
