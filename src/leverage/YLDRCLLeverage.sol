pragma solidity 0.8.23;

import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {CLLeveragedPosition} from "./CLLeveragedPosition.sol";

contract YLDRCLLeverage is Ownable, ERC1155Holder, IERC721Receiver {
    event LeveragedPositionCreated(address indexed position, address indexed user);

    CLLeveragedPosition private leveragePositionImplementation;

    constructor(CLLeveragedPosition _implementation, address _owner) Ownable(_owner) {
        leveragePositionImplementation = _implementation;
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes memory data)
        public
        virtual
        override
        returns (bytes4)
    {
        ERC1155CLWrapper wrapper = leveragePositionImplementation.positionWrapper();
        IPoolAddressesProvider addressesProvider = leveragePositionImplementation.addressesProvider();

        CLLeveragedPosition.PositionInitParams memory params =
            abi.decode(data, (CLLeveragedPosition.PositionInitParams));
        IERC721(msg.sender).safeTransferFrom(address(this), address(wrapper), tokenId);

        // Deploy proxy for user's leveraged position. It is not initialized yet
        address leveragePosition = address(new BeaconProxy(address(this), ""));

        // Supply the position to the pool on behalf of leveraged position proxy
        IPool pool = IPool(addressesProvider.getPool());

        if (!wrapper.isApprovedForAll(address(this), address(pool))) {
            wrapper.setApprovalForAll(address(pool), true);
        }

        pool.supplyERC1155(address(wrapper), tokenId, wrapper.balanceOf(address(this), tokenId), leveragePosition, 0);

        // Call initializer which will perform the actual leveraging logic
        CLLeveragedPosition(leveragePosition).initialize(params);

        emit LeveragedPositionCreated(leveragePosition, from);

        return this.onERC721Received.selector;
    }

    function implementation() external view returns (address) {
        return address(leveragePositionImplementation);
    }

    function updateImplementation(CLLeveragedPosition newImplementation) external {
        _checkOwner();
        leveragePositionImplementation = newImplementation;
    }
}
