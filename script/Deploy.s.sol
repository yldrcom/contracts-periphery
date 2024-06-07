pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
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
import {YLDRCLLeverage} from "../src/leverage/YLDRCLLeverage.sol";
import {CLLeveragedPosition} from "../src/leverage/CLLeveragedPosition.sol";
import {CreateAndLeverage} from "../src/leverage/CreateAndLeverage.sol";
import {YLDRLeverageAutomations, IAssetConverter} from "../src/leverage/YLDRLeverageAutomations.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ITransparentUpgradeableProxy,
    ERC1967Utils,
    ProxyAdmin
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployScript is Script {
    function periphery(
        address weth,
        IPoolAddressesProvider addressesProvider,
        IChainlinkAggregatorV3 networkBaseTokenPriceInUsdProxyAggregator
    ) public {
        vm.startBroadcast();

        UIPoolDataProvider uIPoolDataProvider = new UIPoolDataProvider(networkBaseTokenPriceInUsdProxyAggregator);
        WalletBalanceProvider walletBalancesProvider = new WalletBalanceProvider();
        WETHGateway wETHGateway = new WETHGateway(weth, IPool(addressesProvider.getPool()));

        console.log("UIPoolDataProvider:", address(uIPoolDataProvider));
        console.log("WalletBalanceProvider:", address(walletBalancesProvider));
        console.log("WETHGateway:", address(wETHGateway));
    }

    function clPeriphery(
        IPoolAddressesProvider addressesProvider,
        ERC1155CLWrapper wrapper,
        address multisig,
        address automations
    ) public {
        vm.startBroadcast();

        CLDepositZap depositZap = new CLDepositZap(addressesProvider, wrapper);
        CLLeveragedPosition posImpl = new CLLeveragedPosition(addressesProvider, wrapper, 1000, multisig, automations);
        YLDRCLLeverage leverage = new YLDRCLLeverage(posImpl, multisig);
        CreateAndLeverage createAndLeverage = new CreateAndLeverage(leverage);

        console.log("CLDepositZap:", address(depositZap));
        console.log("Leverage:", address(leverage));
        console.log("CreateAndLeverage:", address(createAndLeverage));

        _deployDataProviders(leverage);
    }

    function _deployDataProviders(YLDRCLLeverage leverage) internal {
        BaseCLAdapter adapter = CLLeveragedPosition(leverage.implementation()).positionWrapper().adapter();
        CLDataProvider dataProvider = new CLDataProvider(adapter);
        CLLeverageDataProvider leverageDataProvider = new CLLeverageDataProvider(dataProvider, leverage);

        console.log("CLDataProvider:", address(dataProvider));
        console.log("CLLeverageDataProvider:", address(leverageDataProvider));
    }

    function dataProviders(YLDRCLLeverage leverage) public {
        vm.startBroadcast();

        _deployDataProviders(leverage);
    }

    function automations(
        IPoolAddressesProvider addressesProvider,
        IAssetConverter assetConverter,
        IERC3156FlashLender[] memory providers
    ) public {
        address multisig = Ownable(address(addressesProvider)).owner();

        vm.startBroadcast();

        YLDRLeverageAutomations automations = YLDRLeverageAutomations(
            address(
                new TransparentUpgradeableProxy(
                    address(new YLDRLeverageAutomations(15, 150, 50, assetConverter, addressesProvider)),
                    multisig,
                    abi.encodeCall(YLDRLeverageAutomations.initialize, ())
                )
            )
        );

        automations.whitelistFlashloanProviders(providers);
        automations.transferOwnership(multisig);
    }

    function deployAndUpgradeAutomations(YLDRLeverageAutomations automations) public {
        vm.startBroadcast();

        YLDRLeverageAutomations newAutomations = new YLDRLeverageAutomations(
            automations.rebalanceFee(),
            automations.deleverageFee(),
            automations.maxSwapSlippage(),
            automations.assetConverter(),
            automations.addressesProvider()
        );

        vm.stopBroadcast();

        ProxyAdmin admin = ProxyAdmin(address(uint160(uint256(vm.load(address(automations), ERC1967Utils.ADMIN_SLOT)))));

        vm.prank(admin.owner());
        bytes memory data = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(address(automations)), address(newAutomations), bytes(""))
        );
        (bool success,) = address(admin).call(data);
        require(success);

        console.log(vm.toString(address(admin)), vm.toString(data));
    }
}
