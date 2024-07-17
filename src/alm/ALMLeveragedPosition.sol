// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC3156FlashLender, IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IYLDROracle} from "@yldr-lending/core/src/interfaces/IYLDROracle.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {IAssetConverter} from "src/interfaces/IAssetConverter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseCLAdapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/BaseCLAdapter.sol";
import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {CLAdapterWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/CLAdapterWrapper.sol";
import {BaseERC20LeveragedPosition} from "../erc20-leverage/BaseERC20LeveragedPosition.sol";
import {ISteerVault} from "@yldr-lending/core/src/interfaces/ext/ISteerVault.sol";
import {BaseALMAdapter} from "./alm-adapters/BaseALMAdapter.sol";
import {ALMAdapterWrapper} from "./ALMAdapterWrapper.sol";

/// @author YLDR <admin@apyflow.com>
contract ALMLeveragedPosition is BaseERC20LeveragedPosition {
    using SafeERC20 for IERC20;
    using ALMAdapterWrapper for BaseALMAdapter;

    BaseALMAdapter public immutable adapter;

    constructor(IPoolAddressesProvider _addressesProvider, BaseALMAdapter _adapter)
        BaseERC20LeveragedPosition(_addressesProvider)
    {
        adapter = _adapter;
    }

    address public token0;
    address public token1;

    function _underlyingTokens() internal virtual override returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
    }

    function initialize(PositionInitParams memory params) public virtual override initializer {
        (token0, token1) = adapter.getVaultTokens(params.lpToken);

        __BaseERC20Leverage__init(params);
    }

    function _divideForMint(uint256 borrowedAmount) internal virtual override returns (uint256[] memory amounts) {
        (uint256 total0, uint256 total1) = adapter.getVaultAmounts(lpToken);
        IYLDROracle oracle = IYLDROracle(addressesProvider.getPriceOracle());
        uint256 usdValue0 = total0 * oracle.getAssetPrice(token0) / (10 ** IERC20Metadata(token0).decimals());
        uint256 usdValue1 = total1 * oracle.getAssetPrice(token1) / (10 ** IERC20Metadata(token1).decimals());

        amounts = new uint256[](2);
        amounts[0] = borrowedAmount * usdValue0 / (usdValue0 + usdValue1);
        amounts[1] = borrowedAmount * usdValue1 / (usdValue0 + usdValue1);
    }

    function _mint(uint256[] memory amounts) internal virtual override returns (uint256 lpAmount) {
        IERC20(token0).forceApprove(lpToken, amounts[0]);
        IERC20(token1).forceApprove(lpToken, amounts[1]);
        (lpAmount,,) = adapter.delegateDeposit(
            BaseALMAdapter.DepositParams({
                vault: lpToken,
                amount0Desired: amounts[0],
                amount1Desired: amounts[1],
                amount0Min: 0,
                amount1Min: 0,
                receiver: address(this)
            })
        );
    }

    function _burn(uint256 lpAmount) internal virtual override returns (uint256[] memory amounts) {
        (uint256 amount0, uint256 amount1) = adapter.delegateWithdraw(
            BaseALMAdapter.WithdrawParams({
                vault: lpToken,
                shares: lpAmount,
                amount0Min: 0,
                amount1Min: 0,
                receiver: address(this)
            })
        );
        amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;
    }
}
