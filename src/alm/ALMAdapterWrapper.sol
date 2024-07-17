// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {BaseALMAdapter} from "./alm-adapters/BaseALMAdapter.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @author YLDR <admin@apyflow.com>
library ALMAdapterWrapper {
    using Address for address;

    function delegateDeposit(BaseALMAdapter adapter, BaseALMAdapter.DepositParams memory params)
        public
        returns (uint256 shares, uint256 amount0Used, uint256 amount1Used)
    {
        return abi.decode(
            address(adapter).functionDelegateCall(abi.encodeCall(adapter.deposit, (params))),
            (uint256, uint256, uint256)
        );
    }

    function delegateWithdraw(BaseALMAdapter adapter, BaseALMAdapter.WithdrawParams memory params)
        public
        returns (uint256 amount0, uint256 amount1)
    {
        return abi.decode(
            address(adapter).functionDelegateCall(abi.encodeCall(adapter.withdraw, (params))), (uint256, uint256)
        );
    }
}
