pragma solidity 0.8.23;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IYLDROracle} from "@yldr-lending/core/src/interfaces/IYLDROracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {IAssetConverter} from "../AssetConverter.sol";
import {
    CLLeveragedPosition, BaseCLAdapter, IERC3156FlashBorrower, IERC3156FlashLender
} from "./CLLeveragedPosition.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract YLDRLeverageAutomations is OwnableUpgradeable {
    address public immutable operator;
    uint256 public immutable rebalanceFee;
    uint256 public immutable deleverageFee;
    uint256 public immutable maxSwapSlippage;
    IAssetConverter public immutable assetConverter;
    IPoolAddressesProvider public immutable addressesProvider;
    mapping(IERC3156FlashLender => bool whitelisted) whitelistedFlashloanProviders;

    event NewCompound(address position);
    event CanceledCompound(address position);
    event NewRebalance(address position);
    event CanceledRebalance(address position);
    event NewDeleverage(address position);
    event CanceledDeleverage(address position);

    constructor(
        uint256 _rebalanceFee,
        uint256 _deleverageFee,
        uint256 _maxSwapSlippage,
        IAssetConverter _assetConverter,
        IPoolAddressesProvider _addressesProvider
    ) {
        rebalanceFee = _rebalanceFee;
        maxSwapSlippage = _maxSwapSlippage;
        deleverageFee = _deleverageFee;
        addressesProvider = _addressesProvider;
        assetConverter = _assetConverter;
        operator = msg.sender;
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
    }

    enum RangeConfigType {
        TICKS,
        PRICE,
        RANGE
    }

    struct RangeConfig {
        RangeConfigType rangeConfigType;
        // For TICKS, ticksDown and ticksUp to count from new position opening tick.
        int24 ticksDown;
        int24 ticksUp;
        // For PRICE sqrtPriceX96Down and sqrtPriceX96Up to count from new position opening price.
        uint160 sqrtPriceX96Down;
        uint160 sqrtPriceX96Up;
    }

    enum EndTriggerType {
        COUNT,
        TIMESTAMP
    }

    struct EndConfig {
        EndTriggerType triggerType;
        uint256 count;
        uint256 timestamp;
    }

    struct RecurringRebalanceConfig {
        RangeConfig rangeConfig;
        EndConfig endConfig;
        bool active;
    }

    struct ScheduledRebalance {
        bool initialized;
        // Trigger ticks for the next rebalance
        int24 triggerLower;
        int24 triggerUpper;
        // Ticks to count down and up when opening new position
        int24 newTicksDown;
        int24 newTicksUp;
        RecurringRebalanceConfig recurring;
        GasFeeConfig gasFeeConfig;
    }

    struct ScheduledCompound {
        bool initialized;
        // Max percent of flashloan fee + gas fee relative to position fees value
        uint256 maxTotalFeePercent;
    }

    struct ScheduledDeleverage {
        bool initialized;
        int24 triggerLower;
        int24 triggerUpper;
        bool withdrawLiquidity;
        GasFeeConfig gasFeeConfig;
    }

    struct GasFeeConfig {
        uint256 maxUsd;
        uint256 maxPositionPercent;
    }

    mapping(address => ScheduledRebalance) public scheduledRebalances;
    mapping(address => ScheduledDeleverage) public scheduledDeleverages;
    mapping(address => ScheduledCompound) public scheduledCompounds;

    function whitelistFlashloanProviders(IERC3156FlashLender[] memory providers) public {
        _checkOwner();

        for (uint256 i = 0; i < providers.length; i++) {
            whitelistedFlashloanProviders[providers[i]] = true;
        }
    }

    function _checkOperator() internal view {
        require(msg.sender == operator, "Only operator can call this function");
    }

    function _checkPositionOwner(address position) internal view {
        require(CLLeveragedPosition(position).owner() == msg.sender, "Only owner can setup rebalance");
    }

    function _checkWhitelistedFlashloanProvider(IERC3156FlashLender provider) internal view {
        require(whitelistedFlashloanProviders[provider], "Flashloan provider not whitelisted");
    }

    function setupRebalance(
        address position,
        int24 triggerLower,
        int24 triggerUpper,
        int24 newTicksDown,
        int24 newTicksUp,
        RecurringRebalanceConfig memory recurring,
        GasFeeConfig memory gasFeeConfig
    ) public {
        _checkPositionOwner(position);

        (BaseCLAdapter adapter, BaseCLAdapter.PositionData memory data) = _getPositionCLAdapterAndData(position);
        address pool = adapter.getPool(data);
        (, int24 currentTick) = adapter.getPoolState(pool);

        require((triggerLower < currentTick) && (triggerUpper > currentTick), "Invalid tick range");

        scheduledRebalances[position] = ScheduledRebalance({
            triggerLower: triggerLower,
            triggerUpper: triggerUpper,
            newTicksDown: newTicksDown,
            newTicksUp: newTicksUp,
            initialized: true,
            recurring: recurring,
            gasFeeConfig: gasFeeConfig
        });

        emit NewRebalance(position);
    }

    function cancelRebalance(address position) public {
        _checkPositionOwner(position);
        delete scheduledRebalances[position];

        emit CanceledRebalance(position);
    }

    function _canRebalance(ScheduledRebalance memory scheduledRebalance, int24 currentTick)
        internal
        pure
        returns (bool)
    {
        if (!scheduledRebalance.initialized) {
            return false;
        }
        return (scheduledRebalance.triggerLower >= currentTick) || (scheduledRebalance.triggerUpper <= currentTick);
    }

    function canRebalance(address position) public view returns (bool) {
        (BaseCLAdapter adapter, BaseCLAdapter.PositionData memory data) = _getPositionCLAdapterAndData(position);
        address pool = adapter.getPool(data);
        (, int24 currentTick) = adapter.getPoolState(pool);

        return _canRebalance(scheduledRebalances[position], currentTick);
    }

    function _getNextRebalanceTriggers(
        RecurringRebalanceConfig memory recurring,
        int24 currentTick,
        int24 newTickLower,
        int24 newTickUpper
    ) internal view returns (bool ended, int24 triggerLower, int24 triggerUpper) {
        if (!recurring.active) {
            return (true, 0, 0);
        }

        if (recurring.endConfig.triggerType == EndTriggerType.COUNT) {
            recurring.endConfig.count -= 1;
            if (recurring.endConfig.count == 0) {
                return (true, 0, 0);
            }
        } else if (recurring.endConfig.triggerType == EndTriggerType.TIMESTAMP) {
            if (block.timestamp >= recurring.endConfig.timestamp) {
                return (true, 0, 0);
            }
        }

        if (recurring.rangeConfig.rangeConfigType == RangeConfigType.TICKS) {
            return (false, currentTick - recurring.rangeConfig.ticksDown, currentTick + recurring.rangeConfig.ticksUp);
        } else if (recurring.rangeConfig.rangeConfigType == RangeConfigType.PRICE) {
            uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(currentTick);
            uint160 sqrtPriceX96Down = (
                recurring.rangeConfig.sqrtPriceX96Down <= (sqrtPriceX96 - TickMath.MIN_SQRT_RATIO)
            ) ? sqrtPriceX96 - recurring.rangeConfig.sqrtPriceX96Down : TickMath.MIN_SQRT_RATIO;
            uint160 sqrtPriceX96Up = (recurring.rangeConfig.sqrtPriceX96Up <= (TickMath.MAX_SQRT_RATIO - sqrtPriceX96))
                ? sqrtPriceX96 + recurring.rangeConfig.sqrtPriceX96Up
                : TickMath.MAX_SQRT_RATIO;

            return (false, TickMath.getTickAtSqrtRatio(sqrtPriceX96Down), TickMath.getTickAtSqrtRatio(sqrtPriceX96Up));
        } else if (recurring.rangeConfig.rangeConfigType == RangeConfigType.RANGE) {
            return (false, newTickLower, newTickUpper);
        }

        return (true, 0, 0);
    }

    function executeRebalance(address position, IERC3156FlashLender flashloanProvider, uint256 usdGasFee) public {
        _checkOperator();
        _checkWhitelistedFlashloanProvider(flashloanProvider);
        (BaseCLAdapter adapter, BaseCLAdapter.PositionData memory data) = _getPositionCLAdapterAndData(position);
        ScheduledRebalance memory scheduledRebalance = scheduledRebalances[position];

        int24 newTickLower;
        int24 newTickUpper;
        int24 currentTick;
        {
            address pool = adapter.getPool(data);
            (, currentTick) = adapter.getPoolState(pool);

            int24 tickSpacing = adapter.getTickSpacing(pool);

            newTickLower = currentTick - scheduledRebalance.newTicksDown;
            newTickUpper = currentTick + scheduledRebalance.newTicksUp;

            newTickLower -= (tickSpacing + newTickLower % tickSpacing) % tickSpacing;
            newTickUpper += (tickSpacing - newTickUpper % tickSpacing) % tickSpacing;
        }

        require(_canRebalance(scheduledRebalance, currentTick), "Rebalance not allowed");
        uint256 fee = _calculateAndValidateFee({
            position: position,
            adapter: adapter,
            positionData: data,
            config: scheduledRebalance.gasFeeConfig,
            usdGasFee: usdGasFee,
            percentFee: rebalanceFee
        });

        CLLeveragedPosition(position).rebalanceAutomation(
            flashloanProvider,
            CLLeveragedPosition.RebalanceParams({
                assetConverter: assetConverter,
                maxSwapSlippage: maxSwapSlippage,
                newTickLower: newTickLower,
                newTickUpper: newTickUpper
            }),
            fee
        );

        (bool shouldDelete, int24 nextTriggerLower, int24 nextTriggerUpper) =
            _getNextRebalanceTriggers(scheduledRebalance.recurring, currentTick, newTickLower, newTickUpper);

        if (shouldDelete) {
            delete scheduledRebalances[position];
        } else {
            scheduledRebalances[position].triggerLower = nextTriggerLower;
            scheduledRebalances[position].triggerUpper = nextTriggerUpper;
            // update as we might alter counter in _getNextRebalanceTriggers
            scheduledRebalances[position].recurring = scheduledRebalance.recurring;
        }
    }

    function setupDeleverage(
        address position,
        int24 triggerLower,
        int24 triggerUpper,
        bool withdrawLiquidity,
        GasFeeConfig memory gasFeeConfig
    ) public {
        _checkPositionOwner(position);

        (BaseCLAdapter adapter, BaseCLAdapter.PositionData memory data) = _getPositionCLAdapterAndData(position);
        address pool = adapter.getPool(data);
        (, int24 currentTick) = adapter.getPoolState(pool);
        require((triggerLower < currentTick) && (triggerUpper > currentTick), "Invalid tick range");

        scheduledDeleverages[position] = ScheduledDeleverage({
            triggerLower: triggerLower,
            triggerUpper: triggerUpper,
            withdrawLiquidity: withdrawLiquidity,
            initialized: true,
            gasFeeConfig: gasFeeConfig
        });

        emit NewDeleverage(position);
    }

    function cancelDeleverage(address position) public {
        _checkPositionOwner(position);
        delete scheduledDeleverages[position];

        emit CanceledDeleverage(position);
    }

    function _canDeleverage(ScheduledDeleverage memory scheduledDeleverage, int24 currentTick)
        internal
        pure
        returns (bool)
    {
        if (!scheduledDeleverage.initialized) {
            return false;
        }
        return (scheduledDeleverage.triggerLower >= currentTick) || (scheduledDeleverage.triggerUpper <= currentTick);
    }

    function canDeleverage(address position) external view returns (bool) {
        (BaseCLAdapter adapter, BaseCLAdapter.PositionData memory data) = _getPositionCLAdapterAndData(position);
        address pool = adapter.getPool(data);
        (, int24 currentTick) = adapter.getPoolState(pool);

        return _canDeleverage(scheduledDeleverages[position], currentTick);
    }

    function executeDeleverage(address position, IERC3156FlashLender flashloanProvider, uint256 usdGasFee) public {
        _checkOperator();
        _checkWhitelistedFlashloanProvider(flashloanProvider);
        ScheduledDeleverage memory scheduledDeleverage = scheduledDeleverages[position];

        (BaseCLAdapter adapter, BaseCLAdapter.PositionData memory data) = _getPositionCLAdapterAndData(position);
        address pool = adapter.getPool(data);
        (, int24 currentTick) = adapter.getPoolState(pool);
        require(_canDeleverage(scheduledDeleverage, currentTick), "Deleverage not allowed");

        uint256 fee = _calculateAndValidateFee({
            position: position,
            adapter: adapter,
            positionData: data,
            config: scheduledDeleverage.gasFeeConfig,
            usdGasFee: usdGasFee,
            percentFee: deleverageFee
        });

        CLLeveragedPosition(position).deleverageAutomation(
            flashloanProvider,
            CLLeveragedPosition.DeleverageParams({
                assetConverter: assetConverter,
                maxSwapSlippage: maxSwapSlippage,
                receiver: CLLeveragedPosition(position).owner(),
                withdrawLiquidity: scheduledDeleverage.withdrawLiquidity
            }),
            fee
        );

        delete scheduledDeleverages[position];
    }

    function setupCompound(address position, uint256 maxTotalFeePercent) public {
        _checkPositionOwner(position);
        scheduledCompounds[position] = ScheduledCompound({initialized: true, maxTotalFeePercent: maxTotalFeePercent});

        emit NewCompound(position);
    }

    function cancelCompound(address position) public {
        _checkPositionOwner(position);
        delete scheduledCompounds[position];

        emit CanceledCompound(position);
    }

    function canCompound(address position, IERC3156FlashLender flashloanProvider, uint256 usdGasFee)
        public
        view
        returns (bool)
    {
        ScheduledCompound memory scheduledCompound = scheduledCompounds[position];
        if (!scheduledCompound.initialized) {
            return false;
        }
        (, uint256 percent) = _calculateCompoundFeeAndPercent(position, flashloanProvider, usdGasFee);
        return percent <= scheduledCompound.maxTotalFeePercent;
    }

    function executeCompound(address position, IERC3156FlashLender flashloanProvider, uint256 usdGasFee) public {
        _checkOperator();
        _checkWhitelistedFlashloanProvider(flashloanProvider);
        ScheduledCompound memory scheduledCompound = scheduledCompounds[position];

        require(scheduledCompound.initialized, "Compound not allowed");

        (uint256 fee, uint256 percent) = _calculateCompoundFeeAndPercent(position, flashloanProvider, usdGasFee);

        require(percent <= scheduledCompounds[position].maxTotalFeePercent, "Fee too high");

        CLLeveragedPosition(position).compoundAutomation(
            flashloanProvider,
            CLLeveragedPosition.CompoundParams({assetConverter: assetConverter, maxSwapSlippage: maxSwapSlippage}),
            fee
        );
    }

    function _calculateCompoundFeeAndPercent(address position, IERC3156FlashLender flashLoanProvider, uint256 usdGasFee)
        internal
        view
        returns (uint256 gasFee, uint256 percent)
    {
        IYLDROracle oracle = IYLDROracle(addressesProvider.getPriceOracle());

        address debtToken = CLLeveragedPosition(position).borrowedToken();

        (BaseCLAdapter adapter, BaseCLAdapter.PositionData memory data) = _getPositionCLAdapterAndData(position);

        uint256 pendingFeesUsd;
        {
            (uint256 fee0, uint256 fee1) = adapter.getPendingFees(data);
            uint256 fee0Usd = fee0 * oracle.getAssetPrice(data.token0) / 10 ** IERC20Metadata(data.token0).decimals();
            uint256 fee1Usd = fee1 * oracle.getAssetPrice(data.token1) / 10 ** IERC20Metadata(data.token1).decimals();

            pendingFeesUsd = fee0Usd + fee1Usd;
        }

        gasFee = usdGasFee * 10 ** IERC20Metadata(debtToken).decimals() / oracle.getAssetPrice(debtToken);
        uint256 flashFee = flashLoanProvider.flashFee(debtToken, CLLeveragedPosition(position).getDebt() + gasFee);
        uint256 flashFeeUsd = flashFee * oracle.getAssetPrice(debtToken) / 10 ** IERC20Metadata(debtToken).decimals();
        percent = (pendingFeesUsd == 0) ? 1e4 : (flashFeeUsd + usdGasFee) * 1e4 / pendingFeesUsd;

        return (gasFee, percent);
    }

    function _getPositionCLAdapterAndData(address position)
        internal
        view
        returns (BaseCLAdapter adapter, BaseCLAdapter.PositionData memory positionData)
    {
        adapter = CLLeveragedPosition(position).positionWrapper().adapter();
        uint256 tokenId = CLLeveragedPosition(position).positionTokenId();
        positionData = adapter.getPositionData(tokenId);
    }

    struct CalcFeeVars {
        IYLDROracle oracle;
        address debtToken;
        uint256 debtTokenPrice;
        uint8 debtTokenDecimals;
        uint256 debt;
        uint256 maxGasFeeUsd;
        address pool;
        uint160 sqrtPriceX96;
        uint256 amount0;
        uint256 amount1;
    }

    function _calculateAndValidateFee(
        address position,
        BaseCLAdapter adapter,
        BaseCLAdapter.PositionData memory positionData,
        GasFeeConfig memory config,
        uint256 usdGasFee,
        uint256 percentFee
    ) internal view returns (uint256) {
        CalcFeeVars memory vars;
        vars.oracle = IYLDROracle(addressesProvider.getPriceOracle());
        vars.debtToken = CLLeveragedPosition(position).borrowedToken();
        vars.debtTokenPrice = vars.oracle.getAssetPrice(vars.debtToken);
        vars.debtTokenDecimals = IERC20Metadata(vars.debtToken).decimals();
        vars.debt = CLLeveragedPosition(position).getDebt();

        uint256 maxGasFeeUsd;
        if (config.maxUsd > 0) {
            maxGasFeeUsd = config.maxUsd;
        } else {
            vars.pool = adapter.getPool(positionData);
            (vars.sqrtPriceX96,) = adapter.getPoolState(vars.pool);
            (vars.amount0, vars.amount1) = LiquidityAmounts.getAmountsForLiquidity(
                vars.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(positionData.tickLower),
                TickMath.getSqrtRatioAtTick(positionData.tickUpper),
                positionData.liquidity
            );
            (uint256 fee0, uint256 fee1) = adapter.getPendingFees(positionData);
            vars.amount0 += fee0;
            vars.amount1 += fee1;

            uint256 token0Price = vars.oracle.getAssetPrice(positionData.token0);
            uint256 token1Price = vars.oracle.getAssetPrice(positionData.token1);

            uint256 usdValue = vars.amount0 * token0Price / (10 ** IERC20Metadata(positionData.token0).decimals())
                + vars.amount1 * token1Price / (10 ** IERC20Metadata(positionData.token1).decimals())
                - vars.debt * vars.debtTokenPrice / (10 ** vars.debtTokenDecimals);

            maxGasFeeUsd = usdValue * config.maxPositionPercent / 1e4;
        }

        require(usdGasFee <= maxGasFeeUsd, "Gas fee too high");

        return (10 ** vars.debtTokenDecimals) * usdGasFee / vars.debtTokenPrice + percentFee * vars.debt / 1e4;
    }

    function getConfiguredAutomations(address[] memory positions)
        public
        view
        returns (
            ScheduledRebalance[] memory rebalances,
            ScheduledDeleverage[] memory deleverages,
            ScheduledCompound[] memory compounds
        )
    {
        rebalances = new ScheduledRebalance[](positions.length);
        deleverages = new ScheduledDeleverage[](positions.length);
        compounds = new ScheduledCompound[](positions.length);

        for (uint256 i = 0; i < positions.length; i++) {
            rebalances[i] = scheduledRebalances[positions[i]];
            deleverages[i] = scheduledDeleverages[positions[i]];
            compounds[i] = scheduledCompounds[positions[i]];
        }
    }
}
