// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/// @author YLDR <admin@apyflow.com>
abstract contract BaseALMAdapter {
    struct DepositParams {
        address vault;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address receiver;
    }

    function deposit(DepositParams memory params)
        public
        virtual
        returns (uint256 shares, uint256 amount0Used, uint256 amount1Used);

    struct WithdrawParams {
        address vault;
        uint256 shares;
        uint256 amount0Min;
        uint256 amount1Min;
        address receiver;
    }

    function withdraw(WithdrawParams memory params) public virtual returns (uint256 amount0, uint256 amount1);

    function getVaultTokens(address vault) public view virtual returns (address token0, address token1);

    function getVaultAmounts(address vault) public view virtual returns (uint256 total0, uint256 total1);
}
