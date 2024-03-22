pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {UIPoolDataProvider} from "../src/ui/UIPoolDataProvider.sol";
import {WalletBalanceProvider} from "../src/ui/WalletBalanceProvider.sol";
import {WETHGateway, IPool} from "../src/WETHGateway.sol";
import {IChainlinkAggregatorV3} from "../src/interfaces/ext/IChainlinkAggregatorV3.sol";
import {UniswapV3Leverage} from "../src/leverage/UniswapV3Leverage.sol";
import {IERC1155UniswapV3Wrapper} from "@yldr-lending/core/src/interfaces/IERC1155UniswapV3Wrapper.sol";
import {UniswapV3DataProvider} from "../src/ui/UniswapV3DataProvider.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {UniswapV3LeverageDataProvider} from "../src/ui/UniswapV3LeverageDataProvider.sol";
import {UniswapV3DepositZap} from "../src/UniswapV3DepositZap.sol";
import {PositionManagerLeverageWrapper} from "../src/leverage/PositionManagerLeverageWrapper.sol";
import {CombinedERC3156Wrapper, IERC3156FlashLender} from "../src/flashloan/CombinedERC3156Wrapper.sol";

contract DeployScript is Script {
    function periphery(
        address weth,
        IPoolAddressesProvider addressesProvider,
        IChainlinkAggregatorV3 networkBaseTokenPriceInUsdProxyAggregator,
        IERC1155UniswapV3Wrapper uniswapV3Wrapper,
        uint256 leverageFee,
        address leverageFeeTreasury
    ) public {
        vm.startBroadcast();

        INonfungiblePositionManager positionManager = uniswapV3Wrapper.positionManager();

        UIPoolDataProvider uIPoolDataProvider = new UIPoolDataProvider(networkBaseTokenPriceInUsdProxyAggregator);
        WalletBalanceProvider walletBalancesProvider = new WalletBalanceProvider();
        WETHGateway wETHGateway = new WETHGateway(weth, IPool(addressesProvider.getPool()));
        UniswapV3DataProvider uniswapV3DataProvider = new UniswapV3DataProvider(positionManager);
        UniswapV3Leverage leverage =
            new UniswapV3Leverage(addressesProvider, uniswapV3Wrapper, leverageFee, leverageFeeTreasury);
        UniswapV3LeverageDataProvider uniswapV3LeverageDataProvider =
            new UniswapV3LeverageDataProvider(uniswapV3DataProvider, leverage);
        UniswapV3DepositZap uniswapV3DepositZap = new UniswapV3DepositZap(addressesProvider, uniswapV3Wrapper);
        PositionManagerLeverageWrapper positionManagerLeverageWrapper =
            new PositionManagerLeverageWrapper(positionManager, leverage);

        console2.log("UIPoolDataProvider:", address(uIPoolDataProvider));
        console2.log("WalletBalanceProvider:", address(walletBalancesProvider));
        console2.log("WETHGateway:", address(wETHGateway));
        console2.log("UniswapV3DataProvider:", address(uniswapV3DataProvider));
        console2.log("UniswapV3Leverage:", address(leverage));
        console2.log("UniswapV3LeverageDataProvider:", address(uniswapV3LeverageDataProvider));
        console2.log("UniswapV3DepositZap:", address(uniswapV3DepositZap));
        console2.log("PositionManagerLeverageWrapper:", address(positionManagerLeverageWrapper));
    }
}
