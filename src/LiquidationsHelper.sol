// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC1155UniswapV3Wrapper} from "@yldr-lending/core/src/interfaces/IERC1155UniswapV3Wrapper.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {IYLDROracle} from "@yldr-lending/core/src/interfaces/IYLDROracle.sol";
import {DataTypes} from "@yldr-lending/core/src/protocol/libraries/types/DataTypes.sol";
import {UserConfiguration} from "@yldr-lending/core/src/protocol/libraries/configuration/UserConfiguration.sol";
import {IERC1155ConfigurationProvider} from "@yldr-lending/core/src/interfaces/IERC1155ConfigurationProvider.sol";
import {IERC1155Supply} from "@yldr-lending/core/src/interfaces/IERC1155Supply.sol";
import {IERC3156FlashLender, IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC1155UniswapV3Wrapper} from "@yldr-lending/core/src/interfaces/IERC1155UniswapV3Wrapper.sol";
import {IAssetConverter} from "src/interfaces/IAssetConverter.sol";

/// @author YLDR <admin@apyflow.com>
contract LiquidationsHelper is IERC3156FlashBorrower, ERC1155Holder, ERC721Holder, Ownable {
    using SafeERC20 for IERC20;
    using UserConfiguration for DataTypes.UserConfigurationMap;

    IPoolAddressesProvider public immutable addressesProvider;
    /// @dev Temproary variable used only to store flash loan provider address during flashloans
    /// Different providers may be used for deposits and withdrawals
    IERC3156FlashLender private flashLoanProvider;

    struct UserCollateralInfo {
        bool erc1155;
        address collateralAsset;
        uint256 collateralTokenId;
        uint256 collateralUSDValue;
    }

    struct UserDebtInfo {
        address debtAsset;
        uint256 debtUSDValue;
    }

    struct FlashloanCallbackParams {
        IPool pool;
        address user;
        UserCollateralInfo collateral;
        UserDebtInfo debt;
        IAssetConverter assetConverter;
    }

    constructor(IPoolAddressesProvider _addressesProvider) Ownable(msg.sender) {
        addressesProvider = _addressesProvider;
    }

    function isLiquidatable(address user) public view returns (bool) {
        IPool pool = IPool(addressesProvider.getPool());
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user);
        return healthFactor < 1e18;
    }

    /// Returns array of liquidatable users, arrays has the form of [user1, user2, address(0), address(0)...]
    function getLiquidatableOnly(address[] calldata users) public view returns (address[] memory liquidatable) {
        liquidatable = new address[](users.length);
        uint256 liquidatableCount = 0;
        for (uint256 i = 0; i < users.length; i++) {
            if (isLiquidatable(users[i])) {
                liquidatable[liquidatableCount++] = users[i];
            }
        }
    }

    struct BestLiquidationOptionVars {
        IPool pool;
        IYLDROracle oracle;
        DataTypes.UserConfigurationMap userConfig;
        address[] reserves;
        UserCollateralInfo maxCollateral;
        UserDebtInfo maxDebt;
        uint256 i;
        DataTypes.ERC1155ReserveUsageData[] usedERC1155Reserves;
    }

    function getBestLiquidationOption(address user)
        public
        view
        returns (UserCollateralInfo memory, UserDebtInfo memory)
    {
        BestLiquidationOptionVars memory vars;
        vars.pool = IPool(addressesProvider.getPool());
        vars.oracle = IYLDROracle(addressesProvider.getPriceOracle());
        require(isLiquidatable(user), "LiquidationsHelper: User is not liquidatable");
        vars.userConfig = vars.pool.getUserConfiguration(user);
        vars.reserves = vars.pool.getReservesList();

        for (vars.i = 0; vars.i < vars.reserves.length; vars.i++) {
            if (vars.userConfig.isUsingAsCollateral(vars.i)) {
                DataTypes.ReserveData memory reserveData = vars.pool.getReserveData(vars.reserves[vars.i]);
                uint256 userBalance = IERC20(reserveData.yTokenAddress).balanceOf(user);
                uint256 usdValue = vars.oracle.getAssetPrice(vars.reserves[vars.i]) * userBalance
                    / (10 ** IERC20Metadata(vars.reserves[vars.i]).decimals());

                if (usdValue > vars.maxCollateral.collateralUSDValue) {
                    vars.maxCollateral = UserCollateralInfo({
                        erc1155: false,
                        collateralAsset: vars.reserves[vars.i],
                        collateralTokenId: 0,
                        collateralUSDValue: usdValue
                    });
                }
            }

            if (vars.userConfig.isBorrowing(vars.i)) {
                DataTypes.ReserveData memory reserveData = vars.pool.getReserveData(vars.reserves[vars.i]);
                uint256 userDebt = IERC20(reserveData.variableDebtTokenAddress).balanceOf(user);
                uint256 usdValue = vars.oracle.getAssetPrice(vars.reserves[vars.i]) * userDebt
                    / (10 ** IERC20Metadata(vars.reserves[vars.i]).decimals());
                if (usdValue > vars.maxDebt.debtUSDValue) {
                    vars.maxDebt = UserDebtInfo({debtAsset: vars.reserves[vars.i], debtUSDValue: usdValue});
                }
            }
        }

        vars.usedERC1155Reserves = vars.pool.getUserUsedERC1155Reserves(user);
        for (vars.i = 0; vars.i < vars.usedERC1155Reserves.length; vars.i++) {
            DataTypes.ERC1155ReserveData memory reserveData =
                vars.pool.getERC1155ReserveData(vars.usedERC1155Reserves[vars.i].asset);
            uint256 userBalance =
                IERC1155Supply(reserveData.nTokenAddress).balanceOf(user, vars.usedERC1155Reserves[vars.i].tokenId);
            uint256 usdValue = vars.oracle.getERC1155AssetPrice(
                vars.usedERC1155Reserves[vars.i].asset, vars.usedERC1155Reserves[vars.i].tokenId
            ) * userBalance
                / IERC1155Supply(vars.usedERC1155Reserves[vars.i].asset).totalSupply(
                    vars.usedERC1155Reserves[vars.i].tokenId
                );
            if (usdValue > vars.maxCollateral.collateralUSDValue) {
                vars.maxCollateral = UserCollateralInfo({
                    erc1155: true,
                    collateralAsset: vars.usedERC1155Reserves[vars.i].asset,
                    collateralTokenId: vars.usedERC1155Reserves[vars.i].tokenId,
                    collateralUSDValue: usdValue
                });
            }
        }

        return (vars.maxCollateral, vars.maxDebt);
    }

    function liquidate(
        address user,
        IERC3156FlashLender _flashloanProvider,
        IAssetConverter _assetConverter,
        UserCollateralInfo calldata collateral,
        UserDebtInfo calldata debt
    ) public onlyOwner {
        IPool pool = IPool(addressesProvider.getPool());
        uint256 debtAmount;
        {
            DataTypes.ReserveData memory reserveData = pool.getReserveData(debt.debtAsset);
            debtAmount = IERC20(reserveData.variableDebtTokenAddress).balanceOf(user);
        }
        if (IERC20(debt.debtAsset).allowance(address(this), address(pool)) < debtAmount) {
            IERC20(debt.debtAsset).forceApprove(address(pool), type(uint256).max);
        }

        _takeFlashloan(
            _flashloanProvider,
            debt.debtAsset,
            debtAmount,
            abi.encode(
                FlashloanCallbackParams({
                    pool: pool,
                    user: user,
                    collateral: collateral,
                    debt: debt,
                    assetConverter: _assetConverter
                })
            )
        );
    }

    /// @notice Function to perform swaps through user-supplied assetConverter.
    /// @param assetConverter Converter which will be used to perform swaps
    /// @param source Token to swap from
    /// @param destination Token to swap to
    /// @param amount Amount to swap
    /// @param maxSlippage Max slippage for swaps
    function _swap(
        IAssetConverter assetConverter,
        address source,
        address destination,
        uint256 amount,
        uint256 maxSlippage
    ) internal returns (uint256 amountOut) {
        if (source == destination) {
            return amount;
        }
        if (amount == 0) {
            return 0;
        }
        if (IERC20(source).allowance(address(this), address(assetConverter)) < amount) {
            IERC20(source).forceApprove(address(assetConverter), type(uint256).max);
        }
        return assetConverter.swap(source, destination, amount, maxSlippage);
    }

    /// @notice Helper function for flashloans. Sets temporary flashLoanProvider storage variable to authorize flashloan
    function _takeFlashloan(IERC3156FlashLender _flashLoanProvider, address token, uint256 amount, bytes memory data)
        internal
    {
        flashLoanProvider = _flashLoanProvider;
        flashLoanProvider.flashLoan(this, token, amount, data);
        flashLoanProvider = IERC3156FlashLender(address(0));
    }

    /// @notice Function which is called by flashloan provider
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 flashFee, bytes calldata data)
        external
        returns (bytes32)
    {
        require(initiator == address(this), "Invalid initiator");
        require(msg.sender == address(flashLoanProvider), "Invalid caller");

        FlashloanCallbackParams memory params = abi.decode(data, (FlashloanCallbackParams));

        if (!params.collateral.erc1155) {
            params.pool.liquidationCall(
                params.collateral.collateralAsset, params.debt.debtAsset, params.user, amount, false
            );

            _swap(
                params.assetConverter,
                params.collateral.collateralAsset,
                params.debt.debtAsset,
                IERC20(params.collateral.collateralAsset).balanceOf(address(this)),
                1000
            );
        } else {
            params.pool.erc1155LiquidationCall(
                params.collateral.collateralAsset,
                params.collateral.collateralTokenId,
                params.debt.debtAsset,
                params.user,
                amount,
                false
            );

            (uint256 amount0, uint256 amount1) = IERC1155UniswapV3Wrapper(params.collateral.collateralAsset).burn(
                address(this),
                params.collateral.collateralTokenId,
                IERC1155UniswapV3Wrapper(params.collateral.collateralAsset).balanceOf(
                    address(this), params.collateral.collateralTokenId
                ),
                address(this)
            );

            (,, address token0, address token1,,,,,,,,) = IERC1155UniswapV3Wrapper(params.collateral.collateralAsset)
                .positionManager().positions(params.collateral.collateralTokenId);

            _swap(params.assetConverter, token0, params.debt.debtAsset, amount0, 1000);
            _swap(params.assetConverter, token1, params.debt.debtAsset, amount1, 1000);
        }

        IERC20(token).safeTransfer(owner(), IERC20(token).balanceOf(address(this)) - amount - flashFee);

        IERC20(token).forceApprove(msg.sender, amount + flashFee);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
