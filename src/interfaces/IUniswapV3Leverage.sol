// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IBeacon} from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";

interface IUniswapV3Leverage is IERC721Receiver, IERC1155Receiver, IBeacon {
    error InvalidCaller();

    event LeveragedPositionCreated(address indexed position, address indexed user);
}
