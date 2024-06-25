pragma solidity 0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ISteerVault} from "@yldr-lending/core/src/interfaces/ext/ISteerVault.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {IYLDROracle} from "@yldr-lending/core/src/interfaces/IYLDROracle.sol";
import {IAssetConverter} from "./interfaces/IAssetConverter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";

contract SteerStrategy is ERC20 {
    using SafeERC20 for IERC20Metadata;

    IERC20Metadata public asset;

    ISteerVault public immutable steerVault;
    IPool public immutable pool;
    IYLDROracle public immutable oracle;

    IERC20Metadata public immutable token0;
    IERC20Metadata public immutable token1;

    IAssetConverter public immutable assetConverter;

    IERC20Metadata public immutable yToken;
    IERC20Metadata public immutable variableDebtToken;

    uint256 public maxSwapSlippage = 50;
    uint256 public targetLtv = 0.5e4;

    enum FlashloanPurpose {
        Deposit,
        Withdraw
    }

    struct DepositParams {
        uint256 amount;
        address user;
    }

    struct WithdrawParams {
        uint256 shares;
        address user;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        IERC20Metadata _asset,
        ISteerVault _steerVault,
        IPoolAddressesProvider _addressesProvider,
        IAssetConverter _assetConverter
    ) ERC20(name_, symbol_) {
        steerVault = _steerVault;
        asset = _asset;

        token0 = IERC20Metadata(steerVault.token0());
        token1 = IERC20Metadata(steerVault.token1());

        assetConverter = _assetConverter;

        pool = IPool(_addressesProvider.getPool());
        oracle = IYLDROracle(_addressesProvider.getPriceOracle());
        yToken = IERC20Metadata(pool.getReserveData(address(steerVault)).yTokenAddress);
        variableDebtToken = IERC20Metadata(pool.getReserveData(address(asset)).variableDebtTokenAddress);

        token0.forceApprove(address(steerVault), type(uint256).max);
        token1.forceApprove(address(steerVault), type(uint256).max);

        asset.forceApprove(address(pool), type(uint256).max);
        IERC20Metadata(address(steerVault)).forceApprove(address(pool), type(uint256).max);
    }

    function totalAssets() public view returns (uint256) {
        uint256 vaultTokenPrice = oracle.getAssetPrice(address(steerVault));
        uint256 assetPrice = oracle.getAssetPrice(address(asset));

        uint256 vaultTokenDecimals = IERC20Metadata(address(steerVault)).decimals();
        uint256 assetDecimals = asset.decimals();

        uint256 usdCollateral = _getSteerSharesAmount() * vaultTokenPrice / (10 ** vaultTokenDecimals);
        uint256 usdBorrowed = _getDebtAmount() * assetPrice / (10 ** assetDecimals);
        uint256 usdAssets = usdCollateral - usdBorrowed;

        return usdAssets * (10 ** assetDecimals) / assetPrice;
    }

    function deposit(uint256 amount) external returns (uint256 shares) {
        uint256 totalAssetsBefore = totalAssets();

        require(amount > 0, "zero amounts");
        asset.safeTransferFrom(msg.sender, address(this), amount);

        uint256 assetsToBorrow = _getAssetsToBorrow(amount);
        _takeFlashloan(
            assetsToBorrow, FlashloanPurpose.Deposit, abi.encode(DepositParams({amount: amount, user: msg.sender}))
        );

        uint256 totalAssetsAfter = totalAssets();

        shares = totalAssetsBefore == 0
            ? totalAssetsAfter
            : (totalAssetsAfter - totalAssetsBefore) * totalSupply() / totalAssetsBefore;

        require(shares > 0, "zero shares");

        _mint(msg.sender, shares);
    }

    function redeem(uint256 shares) external returns (uint256 assets) {
        uint256 debtToRepay = _getDebtAmount() * shares / totalSupply();
        _takeFlashloan(
            debtToRepay, FlashloanPurpose.Withdraw, abi.encode(WithdrawParams({shares: shares, user: msg.sender}))
        );
        assets = asset.balanceOf(address(this));
        asset.safeTransfer(msg.sender, assets);
        _burn(msg.sender, shares);
    }

    function _takeFlashloan(uint256 amount, FlashloanPurpose purpose, bytes memory params) internal {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bool[] memory createPosition = new bool[](1);

        assets[0] = address(asset);
        amounts[0] = amount;
        // only create position for deposit, on withdrawal we are just repaying
        createPosition[0] = purpose == FlashloanPurpose.Deposit;

        pool.flashLoan(address(this), assets, amounts, createPosition, address(this), abi.encode(purpose, params), 0);
    }

    function _divideForMint(uint256 assets) internal view returns (uint256 amount0, uint256 amount1) {
        (uint256 total0, uint256 total1) = steerVault.getTotalAmounts();
        uint256 usdValue0 = total0 * oracle.getAssetPrice(address(token0)) / (10 ** token0.decimals());
        uint256 usdValue1 = total1 * oracle.getAssetPrice(address(token1)) / (10 ** token1.decimals());

        amount0 = assets * usdValue0 / (usdValue0 + usdValue1);
        amount1 = assets * usdValue1 / (usdValue0 + usdValue1);
    }

    function _getSteerSharesAmount() internal view returns (uint256) {
        return yToken.balanceOf(address(this));
    }

    function _getDebtAmount() internal view returns (uint256) {
        return variableDebtToken.balanceOf(address(this));
    }

    function _getAssetsToBorrow(uint256 assets) internal view returns (uint256 assetsToBorrow) {
        uint256 vaultTokenPrice = oracle.getAssetPrice(address(steerVault));
        uint256 assetPrice = oracle.getAssetPrice(address(asset));

        uint256 vaultTokenDecimals = IERC20Metadata(address(steerVault)).decimals();
        uint256 assetDecimals = asset.decimals();

        uint256 usdSupplied = _getSteerSharesAmount() * vaultTokenPrice / (10 ** vaultTokenDecimals);
        uint256 usdBorrowed = _getDebtAmount() * assetPrice / (10 ** assetDecimals);
        uint256 usdAssets = assets * assetPrice / (10 ** assetDecimals);

        uint256 usdToBorrow = (targetLtv * (usdSupplied + usdAssets) / 1e4 - usdBorrowed) * 1e4 / (1e4 - targetLtv);

        assetsToBorrow = usdToBorrow * (10 ** assetDecimals) / assetPrice;
    }

    function _swap(address source, address destination, uint256 amount) internal returns (uint256 amountOut) {
        if (source == destination) {
            return amount;
        }
        if (amount == 0) {
            return 0;
        }
        if (IERC20Metadata(source).allowance(address(this), address(assetConverter)) < amount) {
            IERC20Metadata(source).forceApprove(address(assetConverter), type(uint256).max);
        }
        return assetConverter.swap(source, destination, amount, maxSwapSlippage);
    }

    function executeOperation(
        address[] calldata,
        uint256[] calldata amounts,
        uint256[] calldata,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(pool));
        require(initiator == address(this));

        (FlashloanPurpose purpose, bytes memory _params) = abi.decode(params, (FlashloanPurpose, bytes));

        if (purpose == FlashloanPurpose.Deposit) {
            DepositParams memory args = abi.decode(_params, (DepositParams));
            uint256 amount = args.amount + amounts[0];

            (uint256 amountFor0, uint256 amountFor1) = _divideForMint(amount);

            uint256 amount0 = _swap(address(asset), address(token0), amountFor0);
            uint256 amount1 = _swap(address(asset), address(token1), amountFor1);
            (uint256 shares, uint256 amount0Used, uint256 amount1Used) =
                steerVault.deposit(amount0, amount1, 0, 0, address(this));

            // transfer lefovers to user
            IERC20Metadata(token0).safeTransfer(args.user, amount0 - amount0Used);
            IERC20Metadata(token1).safeTransfer(args.user, amount1 - amount1Used);

            pool.supply(address(steerVault), shares, address(this), 0);
        } else {
            WithdrawParams memory args = abi.decode(_params, (WithdrawParams));

            uint256 sharesToWithdraw = args.shares * _getSteerSharesAmount() / totalSupply();

            pool.repay(address(asset), amounts[0], address(this));
            pool.withdraw(address(steerVault), sharesToWithdraw, address(this));

            (uint256 amount0, uint256 amount1) = steerVault.withdraw(sharesToWithdraw, 0, 0, address(this));

            _swap(address(token0), address(asset), amount0);
            _swap(address(token1), address(asset), amount1);
        }

        return true;
    }
}
