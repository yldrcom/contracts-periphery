// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {BaseALMAdapter} from "./BaseALMAdapter.sol";
import {ISteerVault} from "@yldr-lending/core/src/interfaces/ext/ISteerVault.sol";

/// @author YLDR <admin@apyflow.com>
contract SteerAdapter is BaseALMAdapter {
    function deposit(DepositParams memory params)
        public
        override
        returns (uint256 shares, uint256 amount0Used, uint256 amount1Used)
    {
        return ISteerVault(params.vault).deposit(
            params.amount0Desired, params.amount1Desired, params.amount0Min, params.amount1Min, params.receiver
        );
    }

    function withdraw(WithdrawParams memory params) public override returns (uint256 amount0, uint256 amount1) {
        return ISteerVault(params.vault).withdraw(params.shares, params.amount0Min, params.amount1Min, address(this));
    }

    function getVaultTokens(address vault) public view override returns (address token0, address token1) {
        token0 = ISteerVault(vault).token0();
        token1 = ISteerVault(vault).token1();
    }

    function getVaultAmounts(address vault) public view override returns (uint256 total0, uint256 total1) {
        (total0, total1) = ISteerVault(vault).getTotalAmounts();
    }
}
