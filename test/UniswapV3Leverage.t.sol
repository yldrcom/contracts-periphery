pragma solidity ^0.8.10;

import {
    BaseLeverageTest,
    BaseCLAdapter,
    BaseCLTestingUtils,
    IERC3156FlashLender,
    IERC20Metadata
} from "./BaseLeverageTest.sol";
import {UniswapV3Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/UniswapV3Adapter.sol";
import {UniswapV3TestingUtils} from "./utils/UniswapV3TestingUtils.sol";
import {AaveERC3156Wrapper, IPool as IAavePool} from "../src/flashloan/AaveERC3156Wrapper.sol";
import {AssetConverter, IAssetConverter} from "../src/AssetConverter.sol";
import {UniswapV3Converter, IQuoterV2, IUniswapV3Factory} from "../src/converters/UniswapV3Converter.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

contract UniswapV3LeverageTest is BaseLeverageTest {
    IERC20Metadata usdc = IERC20Metadata(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Metadata weth = IERC20Metadata(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    INonfungiblePositionManager positionManager =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    UniswapV3TestingUtils uniV3Testing;

    function _setup() internal virtual override returns (SetupOutput memory output) {
        vm.createSelectFork("mainnet");
        vm.rollFork(18630167);

        output.adapter = new UniswapV3Adapter(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
        output.testingUtils = new UniswapV3TestingUtils(UniswapV3Adapter(address(output.adapter)));

        output.token0 = usdc;
        output.token1 = weth;

        output.token0Oracle = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
        output.token1Oracle = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

        output.flashloanProvider = new AaveERC3156Wrapper(IAavePool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2));

        uniV3Testing = new UniswapV3TestingUtils(new UniswapV3Adapter(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));
    }

    function _setupConverter(AssetConverter assetConverter) internal virtual override {
        UniswapV3Converter uniswapV3Converter = new UniswapV3Converter(
            IUniswapV3Factory(positionManager.factory()), IQuoterV2(0x61fFE014bA17989E743c5F6cB21bF9697530B21e)
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
    }

    function _moveConverterPrice(uint160 sqrtPriceX96) internal virtual override {
        uniV3Testing.movePoolPrice(address(usdc), address(weth), 500, sqrtPriceX96);
    }
}
