pragma solidity 0.8.23;

import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {IERC1155UniswapV3Wrapper} from "@yldr-lending/core/src/interfaces/IERC1155UniswapV3Wrapper.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {UniswapV3LeveragedPosition} from "./UniswapV3LeveragedPosition.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IUniswapV3Leverage} from "../interfaces/IUniswapV3Leverage.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract UniswapV3Leverage is IUniswapV3Leverage, IBeacon, Ownable, ERC1155Holder {
    IPoolAddressesProvider public immutable addressesProvider;
    IERC1155UniswapV3Wrapper public immutable uniswapV3Wrapper;
    INonfungiblePositionManager public immutable positionManager;
    address private leveragePositionImplementation;

    constructor(IPoolAddressesProvider _addressesProvider, IERC1155UniswapV3Wrapper _uniswapV3Wrapper)
        Ownable(msg.sender)
    {
        addressesProvider = _addressesProvider;
        uniswapV3Wrapper = _uniswapV3Wrapper;
        positionManager = _uniswapV3Wrapper.positionManager();
        leveragePositionImplementation = address(new UniswapV3LeveragedPosition(addressesProvider, _uniswapV3Wrapper));
    }

    function onERC721Received(address, address from, uint256 tokenId, bytes memory data)
        public
        virtual
        override
        returns (bytes4)
    {
        if (msg.sender != address(positionManager)) revert InvalidCaller();

        UniswapV3LeveragedPosition.PositionInitParams memory params =
            abi.decode(data, (UniswapV3LeveragedPosition.PositionInitParams));
        positionManager.safeTransferFrom(address(this), address(uniswapV3Wrapper), tokenId);

        // Deploy proxy for user's leveraged position. It is not initialized yet
        address leveragePosition = address(new BeaconProxy(address(this), ""));

        // Supply the position to the pool on behalf of leveraged position proxy
        IPool pool = IPool(addressesProvider.getPool());

        if (!uniswapV3Wrapper.isApprovedForAll(address(this), address(pool))) {
            uniswapV3Wrapper.setApprovalForAll(address(pool), true);
        }

        pool.supplyERC1155(
            address(uniswapV3Wrapper), tokenId, uniswapV3Wrapper.balanceOf(address(this), tokenId), leveragePosition, 0
        );

        // Call initializer which will perform the actual leveraging logic
        UniswapV3LeveragedPosition(leveragePosition).initialize(params);

        emit LeveragedPositionCreated(leveragePosition, from);

        return this.onERC721Received.selector;
    }

    function implementation() external view override returns (address) {
        return leveragePositionImplementation;
    }

    function updateImplementation(address newImplementation) external {
        _checkOwner();
        leveragePositionImplementation = newImplementation;
    }
}
