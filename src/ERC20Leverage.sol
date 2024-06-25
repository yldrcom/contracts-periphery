pragma solidity 0.8.23;

import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseERC20LeveragedPosition} from "./BaseERC20LeveragedPosition.sol";

contract ERC20Leverage is Ownable {
    using SafeERC20 for IERC20;

    event LeveragedPositionCreated(address indexed position, address indexed user);

    BaseERC20LeveragedPosition private leveragePositionImplementation;

    constructor(BaseERC20LeveragedPosition _implementation, address _owner) Ownable(_owner) {
        leveragePositionImplementation = _implementation;
    }

    function leverage(BaseERC20LeveragedPosition.PositionInitParams memory params) public returns (address position) {
        // Deploy proxy for user's leveraged position. It is not initialized yet
        address leveragePosition = address(new BeaconProxy(address(this), ""));

        IERC20(params.lpToken).safeTransferFrom(msg.sender, leveragePosition, params.lpAmount);

        // Call initializer which will perform the actual leveraging logic
        BaseERC20LeveragedPosition(leveragePosition).initialize(params);

        emit LeveragedPositionCreated(leveragePosition, params.owner);

        return leveragePosition;
    }

    function implementation() external view returns (address) {
        return address(leveragePositionImplementation);
    }

    function updateImplementation(BaseERC20LeveragedPosition newImplementation) external {
        _checkOwner();
        leveragePositionImplementation = newImplementation;
    }
}
