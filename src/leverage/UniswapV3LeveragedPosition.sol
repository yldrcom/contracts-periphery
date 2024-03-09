pragma solidity 0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC3156FlashLender, IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {IERC1155UniswapV3Wrapper} from "@yldr-lending/core/src/interfaces/IERC1155UniswapV3Wrapper.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
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

/// @author YLDR <admin@apyflow.com>
/// @notice This contract represents single leveraged position linked to a specific user
/// This contract's funds mainly stored in yldr protocol and consist of wrapped into ERC1155 Uniswap LP Position
/// and debt.
contract UniswapV3LeveragedPosition is OwnableUpgradeable, ERC1155Holder, ERC721Holder, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    event Deleverage();

    error TooBigPoolPriceDeviation();

    struct Cache {
        IYLDROracle oracle;
        address token0;
        address token1;
        address borrowedToken;
        uint256 positionTokenId;
        uint24 fee;
        IUniswapV3Pool pool;
        uint8 token0Decimals;
        uint8 token1Decimals;
        uint256 token0Price;
        uint256 token1Price;
        uint256 revenueFee;
    }

    enum FlashloanPurpose {
        Deleverage,
        Compound
    }

    /// @notice Id of leveraged position. The safe Id is used in Uniswap V3 position manager and yldr's ERC1155 Uniswap wrapper
    uint256 public positionTokenId;

    IUniswapV3Pool public uniswapV3Pool;
    address public token0;
    address public token1;
    /// @notice Address of token which was borrowed to leverage position
    address public borrowedToken;
    uint24 public fee;
    int24 public tickLower;
    int24 public tickUpper;

    /// @dev Temporary variable used only to store flash loan provider address during flashloans
    /// Different providers may be used for deposits and withdrawals
    IERC3156FlashLender private flashLoanProvider;

    uint256 public revenueFee;
    uint128 public lastFees0;
    uint128 public lastFees1;

    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable uniswapV3Factory;
    IPoolAddressesProvider public immutable addressesProvider;
    IERC1155UniswapV3Wrapper public immutable uniswapV3Wrapper;
    IPool public immutable pool;
    uint256 public immutable revenueFeePercent;
    address public immutable revenueFeeTreasury;

    /// @notice Params which are used to initialize position
    /// @param tokenId ID of position token
    /// @param tokenToBorrow Token which has to be borrowed to leverage position
    /// @param amountToBorrow Amount of token to borrow
    /// @param flashLoanProvider IERC3156-flashloan provider chosen by user which will be used to aquire funds for leveraging
    /// @param assetConverter Converter chosen by user which will be used to swap borrowed token into token0 and token1
    /// @param owner Owner of the position
    /// @param maxSwapSlippage Max slippage for swaps
    struct PositionInitParams {
        uint256 tokenId;
        address tokenToBorrow;
        uint256 amountToBorrow;
        // field not used but kept for backwards compatibility
        IERC3156FlashLender flashLoanProvider;
        IAssetConverter assetConverter;
        address owner;
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

    /// @notice Params which are used to compound fees
    /// @param assetConverter Converter chosen by user which will be used to swap fees to token0 and token1 in needed proportions
    /// @param maxSwapSlippage Max slippage for swaps
    struct CompoundParams {
        IAssetConverter assetConverter;
        uint256 maxSwapSlippage;
    }

    constructor(
        IPoolAddressesProvider _addressesProvider,
        IERC1155UniswapV3Wrapper _uniswapV3Wrapper,
        uint256 _revenueFeePercent,
        address _revenueFeeTreasury
    ) {
        addressesProvider = _addressesProvider;
        pool = IPool(addressesProvider.getPool());
        uniswapV3Wrapper = _uniswapV3Wrapper;
        positionManager = _uniswapV3Wrapper.positionManager();
        uniswapV3Factory = IUniswapV3Factory(positionManager.factory());
        revenueFeePercent = _revenueFeePercent;
        revenueFeeTreasury = _revenueFeeTreasury;
    }

    /// @notice Initializer of the contract. Sets storage variables and performs leveraging operations
    /// 1. Take flashloan
    /// 2. Swap borrowed token into token0 and token1
    /// 3. Increase liquidity of position
    /// 4. Take normal debt at yldr
    /// 5. Repay flashloan with borrowed tokens
    function initialize(PositionInitParams calldata params) public initializer {
        __Ownable_init(params.owner);
        positionTokenId = params.tokenId;
        borrowedToken = params.tokenToBorrow;

        (,, token0, token1, fee, tickLower, tickUpper,,,,,) = positionManager.positions(params.tokenId);
        uniswapV3Pool = IUniswapV3Pool(uniswapV3Factory.getPool(token0, token1, fee));

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bool[] memory createPosition = new bool[](1);

        assets[0] = params.tokenToBorrow;
        amounts[0] = params.amountToBorrow;
        createPosition[0] = true;

        pool.flashLoan(address(this), assets, amounts, createPosition, address(this), abi.encode(params), 0);
    }

    function _getCache() internal view returns (Cache memory cache) {
        IYLDROracle oracle = IYLDROracle(addressesProvider.getPriceOracle());

        return Cache({
            oracle: oracle,
            token0: token0,
            token1: token1,
            borrowedToken: borrowedToken,
            positionTokenId: positionTokenId,
            fee: fee,
            pool: uniswapV3Pool,
            token0Decimals: IERC20Metadata(token0).decimals(),
            token1Decimals: IERC20Metadata(token1).decimals(),
            token0Price: oracle.getAssetPrice(token0),
            token1Price: oracle.getAssetPrice(token1),
            revenueFee: revenueFee
        });
    }

    /// @notice Helper function for flashloans. Sets temporary flashLoanProvider storage variable to authorize flashloan
    function _takeFlashloan(
        IERC3156FlashLender _flashLoanProvider,
        address token,
        uint256 amount,
        FlashloanPurpose purpose,
        bytes memory params
    ) internal {
        flashLoanProvider = _flashLoanProvider;
        flashLoanProvider.flashLoan(this, token, amount, abi.encode(purpose, params));
        flashLoanProvider = IERC3156FlashLender(address(0));
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

    /// @notice Function which uses current pool price and oracle prices to find distribution in which funds should
    /// be divided to supply liquidity in position with as less leftovers as possible.
    function _divideAmountForSwap(Cache memory cache, uint256 amount)
        internal
        view
        returns (uint256 amountToSwapFor0, uint256 amountToSwapFor1)
    {
        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(cache.positionTokenId);

        (uint160 sqrtPriceX96,,,,,,) = uniswapV3Pool.slot0();
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );

        uint256 amount0USD = amount0 * cache.token0Price / (10 ** cache.token0Decimals);
        uint256 amount1USD = amount1 * cache.token1Price / (10 ** cache.token1Decimals);

        amountToSwapFor0 = amount * amount0USD / (amount0USD + amount1USD);
        amountToSwapFor1 = amount - amountToSwapFor0;
    }

    struct DetermineSwapVars {
        uint128 liquidity;
        uint160 sqrtPriceX96;
        uint256 amount0Current;
        uint256 amount1Current;
    }

    /// @notice Function which uses current pool price and oracle prices to find distribution in which funds should
    /// be divided to supply liquidity in position with as less leftovers as possible.
    function _determineNeededSwap(Cache memory cache, uint256 amount0, uint256 amount1)
        internal
        view
        returns (bool zeroForOne, uint256 amount)
    {
        DetermineSwapVars memory vars;

        (,,,,,,, vars.liquidity,,,,) = positionManager.positions(cache.positionTokenId);

        (vars.sqrtPriceX96,,,,,,) = uniswapV3Pool.slot0();
        (vars.amount0Current, vars.amount1Current) = LiquidityAmounts.getAmountsForLiquidity(
            vars.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            vars.liquidity
        );

        uint256 amount0CurrentUSD = vars.amount0Current * cache.token0Price / (10 ** cache.token0Decimals);
        uint256 amount1CurrentUSD = vars.amount1Current * cache.token1Price / (10 ** cache.token1Decimals);
        uint256 amountCurrentTotalUSD = amount0CurrentUSD + amount1CurrentUSD;

        uint256 amount0USD = amount0 * cache.token0Price / (10 ** cache.token0Decimals);
        uint256 amount1USD = amount1 * cache.token1Price / (10 ** cache.token1Decimals);
        uint256 amountTotalUSD = amount0USD + amount1USD;

        // If (amount1USD / amountTotalUSD) < (amount1CurrentUSD / amountCurrentTotalUSD) => zeroForOne = true
        if (amount1USD * amountCurrentTotalUSD < amount1CurrentUSD * amountTotalUSD) {
            uint256 targetAmountUSD = amountTotalUSD * amount1CurrentUSD / amountCurrentTotalUSD;
            return (true, (targetAmountUSD - amount1USD) * (10 ** cache.token0Decimals) / cache.token0Price);
        } else {
            uint256 targetAmountUSD = amountTotalUSD * amount0CurrentUSD / amountCurrentTotalUSD;
            return (false, (targetAmountUSD - amount0USD) * (10 ** cache.token1Decimals) / cache.token1Price);
        }
    }

    function _checkPoolPrice(Cache memory cache, uint256 maxSlippage) internal view {
        (uint160 sqrtPriceX96,,,,,,) = cache.pool.slot0();
        uint256 expectedSqrtPriceX96 = _calculateOracleSqrtPriceX96(cache);
        uint256 _delta = Math.mulDiv(sqrtPriceX96, 1e4, expectedSqrtPriceX96) ** 2 / 1e4;
        uint256 delta = _delta > 1e4 ? _delta - 1e4 : 1e4 - _delta;

        if (delta > maxSlippage) revert TooBigPoolPriceDeviation();
    }

    function _calculateOracleSqrtPriceX96(Cache memory cache) internal pure returns (uint160 sqrtPriceX96) {
        // price = (10 ** token1Decimals) * token0Rate / ((10 ** token0Decimals) * token1Rate)
        // sqrtPriceX96 = sqrt(price * 2^192)

        // overflows only if token0 is 2**160 times more expensive than token1 (considered non-likely)
        uint256 factor1 = Math.mulDiv(cache.token0Price, 2 ** 96, cache.token1Price);

        // Cannot overflow if token1Decimals <= 18 and token0Decimals <= 18
        uint256 factor2 = Math.mulDiv(10 ** cache.token1Decimals, 2 ** 96, 10 ** cache.token0Decimals);

        uint128 factor1Sqrt = uint128(Math.sqrt(factor1));
        uint128 factor2Sqrt = uint128(Math.sqrt(factor2));

        sqrtPriceX96 = factor1Sqrt * factor2Sqrt;
    }

    // helps avoid stack too deep
    struct InitPositionVars {
        uint256 amountToSwapFor0;
        uint256 amountToSwapFor1;
        uint256 amount0;
        uint256 amount1;
        uint256 amount0Resulted;
        uint256 amount1Resulted;
    }

    /// @notice Function which initializes leveraged position
    function _initPositionInsideFlashloan(PositionInitParams memory params) internal {
        Cache memory cache = _getCache();

        _checkPoolPrice(cache, params.maxSwapSlippage);

        InitPositionVars memory vars;

        // Calculate amounts to swap for token0 and token1
        (vars.amountToSwapFor0, vars.amountToSwapFor1) = _divideAmountForSwap(cache, params.amountToBorrow);

        // Do swaps
        vars.amount0 = _swap(
            params.assetConverter, params.tokenToBorrow, cache.token0, vars.amountToSwapFor0, params.maxSwapSlippage
        );
        vars.amount1 = _swap(
            params.assetConverter, params.tokenToBorrow, cache.token1, vars.amountToSwapFor1, params.maxSwapSlippage
        );

        IERC20(cache.token0).forceApprove(address(positionManager), vars.amount0);
        IERC20(cache.token1).forceApprove(address(positionManager), vars.amount1);

        // Add liquidity
        (, vars.amount0Resulted, vars.amount1Resulted) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: cache.positionTokenId,
                amount0Desired: vars.amount0,
                amount1Desired: vars.amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        // Send leftovers to user
        IERC20(cache.token0).safeTransfer(params.owner, vars.amount0 - vars.amount0Resulted);
        IERC20(cache.token1).safeTransfer(params.owner, vars.amount1 - vars.amount1Resulted);

        if (revenueFeePercent > 0) {
            uint256 debtValue = params.amountToBorrow * cache.oracle.getAssetPrice(params.tokenToBorrow)
                / (10 ** IERC20Metadata(params.tokenToBorrow).decimals());
            uint256 positionValue = cache.oracle.getERC1155AssetPrice(address(uniswapV3Wrapper), cache.positionTokenId);

            // Only take revenue fee from borrowed funds
            revenueFee = revenueFeePercent * debtValue / positionValue;

            _updateLastPendingFees(cache);
        }
    }

    function _getPositionUSDValues(Cache memory cache) internal view returns (uint256 usdLiquidity, uint256 usdFees) {
        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(cache.positionTokenId);

        (uint160 sqrtPriceX96,,,,,,) = uniswapV3Pool.slot0();
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
        );

        uint256 amount0USD = amount0 * cache.token0Price / (10 ** cache.token0Decimals);
        uint256 amount1USD = amount1 * cache.token1Price / (10 ** cache.token1Decimals);

        usdLiquidity = amount0USD + amount1USD;

        (uint256 fees0, uint256 fees1) = uniswapV3Wrapper.getPendingFees(cache.positionTokenId);

        uint256 fees0USD = fees0 * cache.token0Price / (10 ** cache.token0Decimals);
        uint256 fees1USD = fees1 * cache.token1Price / (10 ** cache.token1Decimals);

        usdFees = fees0USD + fees1USD;
    }

    /// @notice Helper function for deleveraging position which burns position partly and sends the rest to receiver
    /// It is called when we need to withdraw position, but keep part of it to swap into debt token and repay debt
    ///
    /// In case when we are the only owner of the position, we can just unwrap it and decrease liquidity via position manager
    ///
    /// In case when we are not the only owner of the position (this can happen when position was liquidated), we can't unwrap it,
    /// so we burn all shares, receive token0 and token1 amounts and send part of it to receiver
    function _burnPartAndWithdrawRest(
        Cache memory cache,
        DeleverageAmounts memory amounts,
        address receiver,
        bool withdrawLiquidity
    ) internal returns (uint256 amount0ForRepayment, uint256 amount1ForRepayment) {
        if (amounts.wrappedBalance == amounts.wrappedTotalSupply) {
            // If we are the only owner of the position, we can just unwrap it and withdraw liquidity via position manager
            uniswapV3Wrapper.unwrap(address(this), cache.positionTokenId, address(this));

            (uint256 liquidityToBurn, uint256 liquidityForRepayment, uint256 feesPercentForRepayment) =
                _getAmountsForOwned(cache, amounts, withdrawLiquidity);

            {
                // Those amounts contain amounts returned in exchange for redeemed liquidity, without fees.
                (uint256 amount0FromLiquidity, uint256 amount1FromLiquidity) = positionManager.decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams({
                        tokenId: cache.positionTokenId,
                        liquidity: uint128(liquidityToBurn),
                        amount0Min: 0,
                        amount1Min: 0,
                        deadline: block.timestamp
                    })
                );

                // Only take liquidityForRepayment part of the returned amounts.
                amount0ForRepayment = Math.mulDiv(amount0FromLiquidity, liquidityForRepayment, liquidityToBurn);
                amount1ForRepayment = Math.mulDiv(amount1FromLiquidity, liquidityForRepayment, liquidityToBurn);
            }

            if (feesPercentForRepayment > 0) {
                amount0ForRepayment += Math.mulDiv(amounts.fees0, feesPercentForRepayment, 1e4);
                amount1ForRepayment += Math.mulDiv(amounts.fees1, feesPercentForRepayment, 1e4);
            }

            (uint256 amount0Total, uint256 amount1Total) = positionManager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: cache.positionTokenId,
                    recipient: address(this),
                    // Collect everything if we are withdrawing liquidity, otherwise only amounts for repayment and revenue fees.
                    amount0Max: withdrawLiquidity ? type(uint128).max : uint128(amount0ForRepayment + amounts.revenueFee0),
                    amount1Max: withdrawLiquidity ? type(uint128).max : uint128(amount1ForRepayment + amounts.revenueFee1)
                })
            );

            if (amounts.revenueFee0 > 0) {
                IERC20(cache.token0).safeTransfer(revenueFeeTreasury, amounts.revenueFee0);
            }
            if (amounts.revenueFee1 > 0) {
                IERC20(cache.token1).safeTransfer(revenueFeeTreasury, amounts.revenueFee1);
            }

            if (withdrawLiquidity) {
                IERC20(cache.token0).safeTransfer(receiver, (amount0Total - amount0ForRepayment - amounts.revenueFee0));
                IERC20(cache.token1).safeTransfer(receiver, (amount1Total - amount1ForRepayment - amounts.revenueFee1));
            } else {
                // Send NFT to owner, we don't need it anymore
                positionManager.safeTransferFrom(address(this), receiver, cache.positionTokenId, "");
            }
        } else {
            // If we are not the only owner of LP, we can't unwrap it, so we need to burn our shares
            (uint256 amount0Total, uint256 amount1Total) =
                uniswapV3Wrapper.burn(address(this), positionTokenId, amounts.wrappedBalance, address(this));

            uint256 usdAmountNeeded = amounts.usdRepayment + amounts.usdRevenueFee;
            amount0ForRepayment = Math.mulDiv(usdAmountNeeded, amount0Total, amounts.usdPositionValue);
            amount1ForRepayment = Math.mulDiv(usdAmountNeeded, amount1Total, amounts.usdPositionValue);

            // Send leftovers to user
            IERC20(token0).safeTransfer(receiver, amount0Total - amount0ForRepayment);
            IERC20(token1).safeTransfer(receiver, amount1Total - amount1ForRepayment);

            if (amounts.usdRevenueFee > 0) {
                uint256 amount0ToTreasury = amount0ForRepayment * amounts.usdRevenueFee / usdAmountNeeded;
                uint256 amount1ToTreasury = amount1ForRepayment * amounts.usdRevenueFee / usdAmountNeeded;
                amount0ForRepayment -= amount0ToTreasury;
                amount1ForRepayment -= amount1ToTreasury;
                IERC20(token0).safeTransfer(revenueFeeTreasury, amount0ToTreasury);
                IERC20(token1).safeTransfer(revenueFeeTreasury, amount1ToTreasury);
            }
        }
    }

    /// @notice Returns amounts which should be used for deleveraging position in cases when we are operating on an owned position.
    /// @return liquidityToBurn Total amount of liquidity to burn. 100% if withdrawLiquidity is true,
    /// otherwise only as much as we need for debt repayment
    /// @return liquidityForRepayment Amount of liquidity to burn for debt repayment.
    /// @return feePercentForRepayment Fee percent to be used for debt repayment.
    /// We are trying to avoid touching user fees if possible, so this is set if liquidity is not enough for full debt repayment.
    function _getAmountsForOwned(Cache memory cache, DeleverageAmounts memory amounts, bool withdrawLiquidity)
        internal
        view
        returns (uint256 liquidityToBurn, uint256 liquidityForRepayment, uint256 feePercentForRepayment)
    {
        (,,,,,,, uint128 liquidity,,,,) = positionManager.positions(cache.positionTokenId);

        // We want to avoid touching user fees during repayment if possible.
        if (amounts.usdRepayment <= amounts.usdLiquidityValue) {
            liquidityForRepayment = Math.mulDiv(liquidity, amounts.usdRepayment, amounts.usdLiquidityValue);
        } else {
            liquidityForRepayment = liquidity;
            feePercentForRepayment =
                Math.mulDiv(amounts.usdRepayment - amounts.usdLiquidityValue, 1e4, amounts.usdFeesValue);
        }

        if (withdrawLiquidity) {
            liquidityToBurn = liquidity;
        } else {
            liquidityToBurn = liquidityForRepayment;
        }
    }

    /// @param usdPositionValue value of position liquidity + fees in USD
    /// @param usdLiquidityValue value of position liquidity in USD
    /// @param usdFeesValue value of position fees in USD
    /// @param usdRepayment value needed for debt repayment in USD, including potential slippage costs
    /// @param usdRevenueFee value of revenue fee in USD
    /// @param fees0 amount of token0 fees
    /// @param fees1 amount of token1 fees
    /// @param revenueFee0 amount of token0 revenue fee
    /// @param revenueFee1 amount of token1 revenue fee
    /// @param wrappedBalance balance of wrapped position tokens
    /// @param wrappedTotalSupply total supply of wrapped position tokens
    struct DeleverageAmounts {
        uint256 usdPositionValue;
        uint256 usdLiquidityValue;
        uint256 usdFeesValue;
        uint256 usdRepayment;
        uint256 usdRevenueFee;
        uint256 fees0;
        uint256 fees1;
        uint256 revenueFee0;
        uint256 revenueFee1;
        uint256 wrappedBalance;
        uint256 wrappedTotalSupply;
    }

    function _calculateDeleverageAmounts(
        Cache memory cache,
        uint256 debtAmount,
        uint256 maxSwapSlippage,
        uint256 balance,
        uint256 wrappedTotalSupply
    ) internal view returns (DeleverageAmounts memory amounts) {
        amounts.wrappedBalance = balance;
        amounts.wrappedTotalSupply = wrappedTotalSupply;
        (amounts.usdLiquidityValue, amounts.usdFeesValue) = _getPositionUSDValues(cache);
        amounts.usdPositionValue = balance * (amounts.usdLiquidityValue + amounts.usdFeesValue) / wrappedTotalSupply;
        uint256 debtValue =
            debtAmount * cache.oracle.getAssetPrice(borrowedToken) / (10 ** IERC20Metadata(borrowedToken).decimals());

        // Consider slippage, if we will end up with more than needed, rest will be sent to receiver as well
        amounts.usdRepayment = Math.min(amounts.usdPositionValue, Math.mulDiv(debtValue, (1e4 + maxSwapSlippage), 1e4));
        (amounts.fees0, amounts.fees1) = uniswapV3Wrapper.getPendingFees(cache.positionTokenId);
        if (cache.revenueFee > 0) {
            amounts.revenueFee0 = Math.mulDiv(amounts.fees0 - lastFees0, cache.revenueFee, 1e4);
            amounts.revenueFee1 = Math.mulDiv(amounts.fees1 - lastFees1, cache.revenueFee, 1e4);

            amounts.usdRevenueFee = amounts.revenueFee0 * cache.token0Price / (10 ** cache.token0Decimals)
                + amounts.revenueFee1 * cache.token1Price / (10 ** cache.token1Decimals);

            uint256 maxUSDRevenueFee = amounts.usdPositionValue - amounts.usdRepayment;
            if (amounts.usdRevenueFee > maxUSDRevenueFee) {
                amounts.revenueFee0 = amounts.revenueFee0 * maxUSDRevenueFee / amounts.usdRevenueFee;
                amounts.revenueFee1 = amounts.revenueFee1 * maxUSDRevenueFee / amounts.usdRevenueFee;
                amounts.usdRevenueFee = maxUSDRevenueFee;
            }
        }
    }

    /// @notice Function which deleverages position
    /// @param params Params which are used to deleverage position
    /// @param amount Amount of flashloan
    /// @param flashFee Fee of flashloan
    function _deleverageInsideFlashloan(DeleverageParams memory params, uint256 amount, uint256 flashFee) internal {
        Cache memory cache = _getCache();

        // Repay debt with flashloaned funds
        IERC20(cache.borrowedToken).forceApprove(address(pool), amount);
        if (amount > 0) {
            pool.repay(cache.borrowedToken, amount, address(this));
        }

        // Withdraw LP
        uint256 balance =
            pool.withdrawERC1155(address(uniswapV3Wrapper), cache.positionTokenId, type(uint256).max, address(this));
        uint256 wrappedTotalSupply = uniswapV3Wrapper.totalSupply(cache.positionTokenId);

        DeleverageAmounts memory amounts = _calculateDeleverageAmounts({
            cache: cache,
            debtAmount: amount + flashFee,
            maxSwapSlippage: params.maxSwapSlippage,
            balance: balance,
            wrappedTotalSupply: wrappedTotalSupply
        });

        // Aquire amounts to swap into borrowed token
        (uint256 amount0, uint256 amount1) =
            _burnPartAndWithdrawRest(cache, amounts, params.receiver, params.withdrawLiquidity);

        // Swap tokens to repay debt
        uint256 amountForRepayment = _swap(
            params.assetConverter, cache.token0, cache.borrowedToken, amount0, params.maxSwapSlippage
        ) + _swap(params.assetConverter, cache.token1, cache.borrowedToken, amount1, params.maxSwapSlippage);

        if (amountForRepayment > amount + flashFee) {
            // If we have leftovers, send them to user
            IERC20(cache.borrowedToken).safeTransfer(params.receiver, amountForRepayment - amount - flashFee);
        }
    }

    function _compoundInsideFlashloan(CompoundParams memory params, uint256 debtAmount, uint256 flashFee) internal {
        Cache memory cache = _getCache();
        _checkPoolPrice(cache, params.maxSwapSlippage);

        // Repay debt with flashloaned funds
        IERC20(cache.borrowedToken).forceApprove(address(pool), debtAmount);
        if (debtAmount > 0) {
            pool.repay(cache.borrowedToken, debtAmount, address(this));
        }

        // Withdraw and unwrap LP
        pool.withdrawERC1155(address(uniswapV3Wrapper), cache.positionTokenId, type(uint256).max, address(this));
        uniswapV3Wrapper.unwrap(address(this), cache.positionTokenId, address(this));

        (uint256 amount0, uint256 amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: cache.positionTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        if (cache.revenueFee > 0) {
            uint256 fees0ToTreasury = Math.mulDiv(amount0 - lastFees0, cache.revenueFee, 1e4);
            uint256 fees1ToTreasury = Math.mulDiv(amount1 - lastFees1, cache.revenueFee, 1e4);

            amount0 -= fees0ToTreasury;
            amount1 -= fees1ToTreasury;

            IERC20(token0).safeTransfer(revenueFeeTreasury, fees0ToTreasury);
            IERC20(token1).safeTransfer(revenueFeeTreasury, fees1ToTreasury);
        }

        // Divide and swap rewards
        (bool zeroForOne, uint256 amount) = _determineNeededSwap(cache, amount0, amount1);

        if (zeroForOne) {
            amount0 -= amount;
            amount1 += _swap(params.assetConverter, cache.token0, cache.token1, amount, params.maxSwapSlippage);
        } else {
            amount1 -= amount;
            amount0 += _swap(params.assetConverter, cache.token1, cache.token0, amount, params.maxSwapSlippage);
        }

        IERC20(cache.token0).forceApprove(address(positionManager), amount0);
        IERC20(cache.token1).forceApprove(address(positionManager), amount1);

        // Add liquidity
        (, uint256 amount0Resulted, uint256 amount1Resulted) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: cache.positionTokenId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        if (amount0Resulted < amount0) {
            IERC20(cache.token0).safeTransfer(owner(), amount0 - amount0Resulted);
        }
        if (amount1Resulted < amount1) {
            IERC20(cache.token1).safeTransfer(owner(), amount1 - amount1Resulted);
        }

        positionManager.safeTransferFrom(address(this), address(uniswapV3Wrapper), cache.positionTokenId);

        if (!uniswapV3Wrapper.isApprovedForAll(address(this), address(pool))) {
            uniswapV3Wrapper.setApprovalForAll(address(pool), true);
        }

        pool.supplyERC1155(
            address(uniswapV3Wrapper),
            cache.positionTokenId,
            uniswapV3Wrapper.balanceOf(address(this), cache.positionTokenId),
            address(this),
            0
        );

        pool.borrow(cache.borrowedToken, debtAmount + flashFee, 0, address(this));

        if (revenueFee > 0) {
            _updateLastPendingFees(cache);
        }
    }

    function executeOperation(
        address[] calldata,
        uint256[] calldata,
        uint256[] calldata,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        require(msg.sender == address(pool), "Only pool can call this function");
        require(initiator == address(this), "Only this contract can initiate flash loan");

        _initPositionInsideFlashloan(abi.decode(params, (PositionInitParams)));

        return true;
    }

    /// @notice Function which is called by flashloan provider
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 flashFee, bytes calldata data)
        external
        returns (bytes32)
    {
        require(initiator == address(this), "Invalid initiator");
        require(msg.sender == address(flashLoanProvider), "Invalid caller");

        (FlashloanPurpose purpose, bytes memory params) = abi.decode(data, (FlashloanPurpose, bytes));

        if (purpose == FlashloanPurpose.Deleverage) {
            _deleverageInsideFlashloan(abi.decode(params, (DeleverageParams)), amount, flashFee);
        } else if (purpose == FlashloanPurpose.Compound) {
            _compoundInsideFlashloan(abi.decode(params, (CompoundParams)), amount, flashFee);
        }

        IERC20(token).forceApprove(msg.sender, amount + flashFee);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    /// @notice Function only callable by position owner to deleverage position
    /// It performs following steps:
    /// 1. Take flashloan
    /// 2. Repay debt with flashloaned funds
    /// 3. Withdraw position
    /// 4. Use part of position's funds to swap token0 and token1 into debt token
    /// 5. Send the rest of position funds to receiver
    /// 6. Repay flashloan with tokens taken from position
    function deleverage(IERC3156FlashLender flashloanProvider, DeleverageParams memory params) external {
        _checkOwner();
        uint256 debtToCover = IERC20(
            IPool(addressesProvider.getPool()).getReserveData(borrowedToken).variableDebtTokenAddress
        ).balanceOf(address(this));
        _takeFlashloan(flashloanProvider, borrowedToken, debtToCover, FlashloanPurpose.Deleverage, abi.encode(params));

        emit Deleverage();
    }

    /// @notice Function only callable by position owner to compound fees
    /// It performs following steps:
    /// 1. Take flashloan
    /// 2. Repay debt with flashloaned funds
    /// 3. Withdraw and unwrap position
    /// 5. collect, divide, swap and reinvest fees
    /// 6. Supply position
    /// 7. Borrow flashloaned amount against the position
    /// 8. Repay flashloan with borrowed tokens
    function compound(IERC3156FlashLender flashloanProvider, CompoundParams memory params) external {
        _checkOwner();

        uint256 debtToCover = IERC20(
            IPool(addressesProvider.getPool()).getReserveData(borrowedToken).variableDebtTokenAddress
        ).balanceOf(address(this));

        _takeFlashloan(flashloanProvider, borrowedToken, debtToCover, FlashloanPurpose.Compound, abi.encode(params));
    }

    function _updateLastPendingFees(Cache memory cache) internal {
        (uint256 fees0, uint256 fees1) = uniswapV3Wrapper.getPendingFees(cache.positionTokenId);
        lastFees0 = uint128(fees0);
        lastFees1 = uint128(fees1);
    }
}
