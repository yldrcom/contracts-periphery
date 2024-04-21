pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {UIPoolDataProvider} from "../src/ui/UIPoolDataProvider.sol";
import {WalletBalanceProvider} from "../src/ui/WalletBalanceProvider.sol";
import {WETHGateway, IPool} from "../src/WETHGateway.sol";
import {IChainlinkAggregatorV3} from "../src/interfaces/ext/IChainlinkAggregatorV3.sol";
import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {CLLeverageDataProvider} from "../src/ui/CLLeverageDataProvider.sol";
import {CLDepositZap} from "../src/CLDepositZap.sol";
import {CombinedERC3156Wrapper, IERC3156FlashLender} from "../src/flashloan/CombinedERC3156Wrapper.sol";
import {BaseCLAdapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/BaseCLAdapter.sol";
import {CLDataProvider} from "../src/ui/CLDataProvider.sol";

contract DeployScript is Script {
    function periphery(
        address weth,
        IPoolAddressesProvider addressesProvider,
        IChainlinkAggregatorV3 networkBaseTokenPriceInUsdProxyAggregator,
        ERC1155CLWrapper wrapper
    ) public {
        vm.startBroadcast();

        BaseCLAdapter adapter = wrapper.adapter();

        UIPoolDataProvider uIPoolDataProvider = new UIPoolDataProvider(networkBaseTokenPriceInUsdProxyAggregator);
        WalletBalanceProvider walletBalancesProvider = new WalletBalanceProvider();
        WETHGateway wETHGateway = new WETHGateway(weth, IPool(addressesProvider.getPool()));
        CLDataProvider uniswapV3DataProvider = new CLDataProvider(adapter);
        CLDepositZap uniswapV3DepositZap = new CLDepositZap(addressesProvider, wrapper);

        console2.log("UIPoolDataProvider:", address(uIPoolDataProvider));
        console2.log("WalletBalanceProvider:", address(walletBalancesProvider));
        console2.log("WETHGateway:", address(wETHGateway));
        console2.log("CLDataProvider:", address(uniswapV3DataProvider));
        console2.log("CLDepositZap:", address(uniswapV3DepositZap));
    }
}
