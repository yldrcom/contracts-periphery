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

abstract contract BaseERC20LeveragedPosition is OwnableUpgradeable, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    error InvalidCaller();
    error InvalidInitiator();

    struct PositionInitParams {
        address lpToken;
        uint256 lpAmount;
        address tokenToBorrow;
        uint256 amountToBorrow;
        IAssetConverter assetConverter;
        uint256 maxSwapSlippage;
    }

    /// @notice Params which are used to deleverage position
    /// @param assetConverter Converter chosen by user which will be used to swap token0 and token1 into borrowed token
    /// @param maxSwapSlippage Max slippage for swaps
    /// @param receiver Address which will receive leftover tokens after deleveraging
    struct DeleverageParams {
        IAssetConverter assetConverter;
        uint256 maxSwapSlippage;
        address receiver;
        bool withdrawLiquidity;
    }

    IPoolAddressesProvider public immutable addressesProvider;
    IPool public immutable pool;

    address public lpToken;
    address public tokenToBorrow;

    /// @dev Temporary variable used only to store flash loan provider address during flashloans
    /// Different providers may be used for deposits and withdrawals
    IERC3156FlashLender private flashLoanProvider;

    constructor(IPoolAddressesProvider _addressesProvider) {
        addressesProvider = _addressesProvider;
        pool = IPool(addressesProvider.getPool());
    }

    function __BaseERC20Leverage__init(PositionInitParams memory params) internal onlyInitializing {
        __Ownable_init(msg.sender);
        lpToken = params.lpToken;
        tokenToBorrow = params.tokenToBorrow;

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bool[] memory createPosition = new bool[](1);

        assets[0] = params.tokenToBorrow;
        amounts[0] = params.amountToBorrow;
        createPosition[0] = true;

        IERC20(params.lpToken).forceApprove(address(pool), type(uint256).max);

        pool.supply(lpToken, params.lpAmount, address(this), 0);
        pool.flashLoan(address(this), assets, amounts, createPosition, address(this), abi.encode(params), 0);
    }

    /// @notice Helper function for flashloans. Sets temporary flashLoanProvider storage variable to authorize flashloan
    function _takeFlashloan(IERC3156FlashLender _flashLoanProvider, address token, uint256 amount, bytes memory params)
        internal
    {
        flashLoanProvider = _flashLoanProvider;
        flashLoanProvider.flashLoan(this, token, amount, params);
        flashLoanProvider = IERC3156FlashLender(address(0));
    }

    function deleverage(IERC3156FlashLender flashloanProvider, DeleverageParams memory params) external {
        _checkOwner();

        _takeFlashloan(flashloanProvider, tokenToBorrow, getDebt(), abi.encode(params));
    }

    function _deleverageInsideFlashloan(DeleverageParams memory params, uint256 flashAmount, uint256 flashFee)
        internal
    {
        address[] memory underlyingTokens = _underlyingTokens();
        _repayFullDebt();

        uint256 usdDebt;
        uint256 lpTokenPrice;
        uint256 usdToBurn;
        {
            IYLDROracle oracle = IYLDROracle(addressesProvider.getPriceOracle());
            usdDebt = (flashAmount + flashFee) * oracle.getAssetPrice(tokenToBorrow)
                / (10 ** IERC20Metadata(tokenToBorrow).decimals());
            lpTokenPrice = oracle.getAssetPrice(lpToken);
            uint256 lpBalance = pool.withdraw(lpToken, type(uint256).max, address(this));
            uint256 usdLpValue = lpBalance * lpTokenPrice / (10 ** IERC20Metadata(lpToken).decimals());

            if (params.withdrawLiquidity) {
                usdToBurn = usdLpValue;
            } else {
                usdToBurn = usdDebt;
            }
        }
        uint256 debtTokenAmount = 0;
        uint256[] memory amounts = _burn(usdToBurn * (10 ** IERC20Metadata(lpToken).decimals()) / lpTokenPrice);

        {
            for (uint256 i = 0; i < amounts.length; i++) {
                uint256 amountToSwap = amounts[i] * usdDebt / usdToBurn;
                debtTokenAmount += _swap(
                    params.assetConverter, underlyingTokens[i], tokenToBorrow, amountToSwap, params.maxSwapSlippage
                );
                uint256 left = amounts[i] - amountToSwap;

                if (left > 0) {
                    IERC20(underlyingTokens[i]).safeTransfer(params.receiver, left);
                }
            }

            if (debtTokenAmount > (flashAmount + flashFee)) {
                IERC20(tokenToBorrow).safeTransfer(params.receiver, debtTokenAmount - (flashAmount + flashFee));
            }
        }
    }

    function _divideForMint(uint256 borrowedAmount) internal virtual returns (uint256[] memory amounts);
    function _mint(uint256[] memory amounts) internal virtual returns (uint256 lpAmount);
    function _burn(uint256 lpAmount) internal virtual returns (uint256[] memory amounts);
    function _underlyingTokens() internal virtual returns (address[] memory tokens);

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

    function executeOperation(
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        address initiator,
        bytes calldata _params
    ) external returns (bool) {
        if (msg.sender != address(pool)) revert InvalidCaller();
        if (initiator != address(this)) revert InvalidInitiator();

        address[] memory underlyingTokens = _underlyingTokens();

        PositionInitParams memory params = abi.decode(_params, (PositionInitParams));

        uint256[] memory amounts = _divideForMint(params.amountToBorrow);
        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] =
                _swap(params.assetConverter, underlyingTokens[i], tokenToBorrow, amounts[i], params.maxSwapSlippage);
        }
        uint256 lpAmount = _mint(amounts);
        pool.supply(lpToken, lpAmount, address(this), 0);

        return true;
    }

    /// @notice Function which is called by flashloan provider
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 flashFee, bytes calldata data)
        external
        returns (bytes32)
    {
        if (msg.sender != address(flashLoanProvider)) revert InvalidCaller();
        if (initiator != address(this)) revert InvalidInitiator();

        DeleverageParams memory params = abi.decode(data, (DeleverageParams));

        _deleverageInsideFlashloan(params, amount, flashFee);

        IERC20(token).forceApprove(msg.sender, amount + flashFee);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    function getDebt() public view returns (uint256) {
        return IERC20(IPool(addressesProvider.getPool()).getReserveData(tokenToBorrow).variableDebtTokenAddress)
            .balanceOf(address(this));
    }

    function _repayFullDebt() internal {
        uint256 debt = getDebt();
        if (debt == 0) return;
        IERC20(tokenToBorrow).forceApprove(address(pool), debt);
        pool.repay(tokenToBorrow, debt, address(this));
    }
}
