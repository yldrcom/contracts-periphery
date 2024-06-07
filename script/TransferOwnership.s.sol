pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {YLDRCLLeverage} from "../src/leverage/YLDRCLLeverage.sol";
import {IACLManager} from "@yldr-lending/core/src/interfaces/IACLManager.sol";
import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {CLLeveragedPosition} from "../src/leverage/CLLeveragedPosition.sol";
import {
    ITransparentUpgradeableProxy,
    ERC1967Utils
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {YLDRLeverageAutomations} from "../src/leverage/YLDRLeverageAutomations.sol";

contract TransferOwnershipScript is Script {
    function run(
        IPoolAddressesProvider addressesProvider,
        YLDRCLLeverage leverage,
        address multisig,
        address[] memory converters,
        YLDRLeverageAutomations automations
    ) public {
        vm.startBroadcast();

        (, address deployer,) = vm.readCallers();

        if (Ownable(address(addressesProvider)).owner() == deployer) {
            IACLManager aclManager = IACLManager(addressesProvider.getACLManager());
            aclManager.addPoolAdmin(multisig);
            aclManager.removePoolAdmin(deployer);
            addressesProvider.setACLAdmin(multisig);

            _handleOwnable(address(addressesProvider), multisig);
        }

        _handleOwnable(address(leverage), multisig);

        ERC1155CLWrapper wrapper = CLLeveragedPosition(leverage.implementation()).positionWrapper();

        _handleProxy(address(wrapper), multisig);
        _handleOwnable(address(automations), multisig);

        for (uint256 i = 0; i < converters.length; i++) {
            _handleOwnable(converters[i], multisig);
        }
    }

    function _handleOwnable(address _contract, address newOwner) internal {
        (, address deployer,) = vm.readCallers();

        address currentOwner = Ownable(_contract).owner();

        if (currentOwner == newOwner) {
            return;
        }

        if (currentOwner == deployer) {
            Ownable(_contract).transferOwnership(deployer);
        } else {
            revert(string.concat("Contract is owned by ", vm.toString(currentOwner)));
        }
    }

    function _handleProxy(address proxy, address newAdmin) internal {
        address proxyAdmin = address(uint160(uint256(vm.load(proxy, ERC1967Utils.ADMIN_SLOT))));

        _handleOwnable(proxyAdmin, newAdmin);
    }
}
