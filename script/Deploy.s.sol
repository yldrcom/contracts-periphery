pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {UIPoolDataProvider} from "../src/ui/UIPoolDataProvider.sol";
import {WalletBalanceProvider} from "../src/ui/WalletBalanceProvider.sol";
import {WETHGateway, IPool} from "../src/WETHGateway.sol";
import {IChainlinkAggregatorV3} from "../src/interfaces/ext/IChainlinkAggregatorV3.sol";
import {BaseERC1155CLWrapper} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/erc1155-wrappers/BaseERC1155CLWrapper.sol";
import {UniswapV3DataProvider} from "../src/ui/UniswapV3DataProvider.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {CLLeverageDataProvider} from "../src/ui/CLLeverageDataProvider.sol";
import {CLDepositZap} from "../src/CLDepositZap.sol";
import {UniswapV3CreateAndLeverage} from "../src/leverage/create-and-leverage/UniswapV3CreateAndLeverage.sol";
import {CombinedERC3156Wrapper, IERC3156FlashLender} from "../src/flashloan/CombinedERC3156Wrapper.sol";

contract DeployScript is Script {
    function periphery(
        address weth,
        IPoolAddressesProvider addressesProvider,
        IChainlinkAggregatorV3 networkBaseTokenPriceInUsdProxyAggregator,
        BaseERC1155CLWrapper uniswapV3Wrapper
    ) public {
        vm.startBroadcast();

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(uniswapV3Wrapper.getPositionManager());

        UIPoolDataProvider uIPoolDataProvider = new UIPoolDataProvider(networkBaseTokenPriceInUsdProxyAggregator);
        WalletBalanceProvider walletBalancesProvider = new WalletBalanceProvider();
        WETHGateway wETHGateway = new WETHGateway(weth, IPool(addressesProvider.getPool()));
        UniswapV3DataProvider uniswapV3DataProvider = new UniswapV3DataProvider(address(positionManager));
        CLDepositZap uniswapV3DepositZap = new CLDepositZap(addressesProvider, uniswapV3Wrapper);

        console2.log("UIPoolDataProvider:", address(uIPoolDataProvider));
        console2.log("WalletBalanceProvider:", address(walletBalancesProvider));
        console2.log("WETHGateway:", address(wETHGateway));
        console2.log("UniswapV3DataProvider:", address(uniswapV3DataProvider));
        console2.log("CLDepositZap:", address(uniswapV3DepositZap));
    }
}
