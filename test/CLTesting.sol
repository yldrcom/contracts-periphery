pragma solidity ^0.8.10;

import {BaseCLAdapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/BaseCLAdapter.sol";
import {PoolTesting} from "@yldr-lending/core/test/libraries/PoolTesting.sol";
import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {ERC1155CLWrapperConfigurationProvider} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapperConfigurationProvider.sol";
import {ERC1155CLWrapperOracle} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapperOracle.sol";
import {CLDataProvider} from "../src/ui/CLDataProvider.sol";
import {YLDRCLLeverage} from "../src/leverage/YLDRCLLeverage.sol";
import {CLLeverageDataProvider} from "../src/ui/CLLeverageDataProvider.sol";
import {CLLeveragedPosition} from "../src/leverage/CLLeveragedPosition.sol";
import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {YLDRFeeCollector} from "../src/YLDRFeeCollector.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {CLLeveragedPosition} from "../src/leverage/CLLeveragedPosition.sol";
import {YLDRLeverageAutomations} from "../src/leverage/YLDRLeverageAutomations.sol";
import {IAssetConverter} from "../src/AssetConverter.sol";

library CLTesting {
    using PoolTesting for PoolTesting.Data;

    struct Data {
        IPoolAddressesProvider addressesProvider;
        address admin;
        BaseCLAdapter adapter;
        ERC1155CLWrapper wrapper;
        CLDataProvider dataProvider;
        YLDRCLLeverage leverage;
        CLLeverageDataProvider leverageDataProvider;
        YLDRFeeCollector feeCollector;
        IERC721 positionManager;
        YLDRLeverageAutomations leverageAutomations;
    }

    function init(
        Data storage self,
        PoolTesting.Data storage poolTesting,
        BaseCLAdapter adapter,
        IAssetConverter assetConverter
    ) internal {
        self.admin = poolTesting.admin;
        self.addressesProvider = poolTesting.addressesProvider;
        self.adapter = adapter;
        self.wrapper = ERC1155CLWrapper(
            address(
                new TransparentUpgradeableProxy(
                    address(new ERC1155CLWrapper(self.adapter)),
                    poolTesting.admin,
                    abi.encodeCall(ERC1155CLWrapper.initialize, ())
                )
            )
        );
        self.dataProvider = new CLDataProvider(adapter);
        self.leverageAutomations =
            new YLDRLeverageAutomations(15, 150, 50, assetConverter, poolTesting.addressesProvider);
        self.leverage = new YLDRCLLeverage(
            new CLLeveragedPosition(
                poolTesting.addressesProvider, self.wrapper, 1000, poolTesting.admin, address(self.leverageAutomations)
            ),
            poolTesting.admin
        );
        self.leverageDataProvider = new CLLeverageDataProvider(self.dataProvider, self.leverage);
        self.feeCollector = new YLDRFeeCollector(poolTesting.admin, poolTesting.admin);
        self.positionManager = IERC721(adapter.getPositionManager());

        poolTesting.addERC1155Reserve(
            address(self.wrapper),
            address(new ERC1155CLWrapperConfigurationProvider(poolTesting.addressesProvider, self.wrapper)),
            address(new ERC1155CLWrapperOracle(poolTesting.addressesProvider, self.wrapper)),
            address(self.feeCollector),
            0.2e4
        );
    }

    function disableRevenueFee(Data storage self) internal {
        self.leverage.updateImplementation(
            new CLLeveragedPosition(
                self.addressesProvider, self.wrapper, 0, self.admin, address(self.leverageAutomations)
            )
        );
    }
}
