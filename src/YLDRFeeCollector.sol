pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155UniswapV3Wrapper} from "@yldr-lending/core/src/interfaces/IERC1155UniswapV3Wrapper.sol";
import {INToken} from "@yldr-lending/core/src/interfaces/INToken.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

/// @author YLDR <admin@apyflow.com>
contract YLDRFeeCollector is Ownable, IERC1155Receiver {
    error InvalidCaller();

    IERC1155UniswapV3Wrapper public immutable uniswapV3Wrapper;
    address public treasury;

    constructor(IERC1155UniswapV3Wrapper _uniswapV3Wrapper, address _treasury, address _owner) Ownable(_owner) {
        uniswapV3Wrapper = _uniswapV3Wrapper;
        treasury = _treasury;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function onERC1155Received(address, address, uint256 id, uint256 value, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(uniswapV3Wrapper)) revert InvalidCaller();

        uniswapV3Wrapper.burn(address(this), id, value, treasury);

        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata ids, uint256[] calldata values, bytes calldata)
        external
        returns (bytes4)
    {
        if (msg.sender != address(uniswapV3Wrapper)) revert InvalidCaller();

        for (uint256 i = 0; i < ids.length; i++) {
            uniswapV3Wrapper.burn(address(this), ids[i], values[i], treasury);
        }

        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}
