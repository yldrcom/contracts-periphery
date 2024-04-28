pragma solidity ^0.8.10;

import {
    BaseLeverageTest,
    BaseCLAdapter,
    BaseCLTestingUtils,
    IERC3156FlashLender,
    IERC20Metadata
} from "./BaseLeverageTest.sol";
import {AlgebraV1Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/AlgebraV1Adapter.sol";
import {AlgebraV1TestingUtils} from "./utils/AlgebraV1TestingUtils.sol";
import {AaveERC3156Wrapper, IPool as IAavePool} from "../src/flashloan/AaveERC3156Wrapper.sol";
import {AssetConverter, IAssetConverter} from "../src/AssetConverter.sol";
import {UniswapV3Converter, IQuoterV2, IUniswapV3Factory} from "../src/converters/UniswapV3Converter.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {UniswapV3TestingUtils} from "./utils/UniswapV3TestingUtils.sol";
import {UniswapV3Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/UniswapV3Adapter.sol";

contract AlgebraV1LeverageTest is BaseLeverageTest {
    IERC20Metadata usdc = IERC20Metadata(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    IERC20Metadata weth = IERC20Metadata(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IUniswapV3Factory factory = IUniswapV3Factory(0x1F98431c8aD98523631AE4a59f267346ea31F984);

    UniswapV3TestingUtils uniV3Testing;

    function _setup() internal virtual override returns (SetupOutput memory output) {
        vm.createSelectFork("arbitrum_one");
        vm.rollFork(197388780);

        output.adapter = new AlgebraV1Adapter(0x00c7f3082833e796A5b3e4Bd59f6642FF44DCD15);
        output.testingUtils = new AlgebraV1TestingUtils(AlgebraV1Adapter(address(output.adapter)));

        output.token0 = weth;
        output.token1 = usdc;

        output.token0Oracle = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
        output.token1Oracle = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

        output.flashloanProvider = new AaveERC3156Wrapper(IAavePool(0x794a61358D6845594F94dc1DB02A252b5b4814aD));

        uniV3Testing = new UniswapV3TestingUtils(new UniswapV3Adapter(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));
    }

    function _setupConverter(AssetConverter assetConverter) internal virtual override {
        UniswapV3Converter uniswapV3Converter =
            new UniswapV3Converter(factory, IQuoterV2(0x61fFE014bA17989E743c5F6cB21bF9697530B21e));

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
    }

    function _moveConverterPrice(uint160 sqrtPriceX96) internal virtual override {
        uniV3Testing.movePoolPrice(address(weth), address(usdc), 500, sqrtPriceX96);
    }
}
