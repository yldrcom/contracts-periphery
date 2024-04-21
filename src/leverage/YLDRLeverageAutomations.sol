pragma solidity 0.8.23;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IYLDROracle} from "@yldr-lending/core/src/interfaces/IYLDROracle.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolAddressesProvider} from "@yldr-lending/core/src/interfaces/IPoolAddressesProvider.sol";
import {ERC1155CLWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155CLWrapper.sol";
import {IAssetConverter} from "../AssetConverter.sol";
import {
    CLLeveragedPosition, BaseCLAdapter, IERC3156FlashBorrower, IERC3156FlashLender
} from "./CLLeveragedPosition.sol";

contract YLDRLeverageAutomations is Ownable {
    uint256 public rebalanceFee;
    uint256 public deleverageFee;
    uint256 public maxSwapSlippage;
    IAssetConverter public assetConverter;
    IPoolAddressesProvider public immutable addressesProvider;

    constructor(
        uint256 _rebalanceFee,
        uint256 _deleverageFee,
        uint256 _maxSwapSlippage,
        IAssetConverter _assetConverter,
        IPoolAddressesProvider _addressesProvider
    ) Ownable(msg.sender) {
        rebalanceFee = _rebalanceFee;
        maxSwapSlippage = _maxSwapSlippage;
        deleverageFee = _deleverageFee;
        addressesProvider = _addressesProvider;
        assetConverter = _assetConverter;
    }

    enum RangeConfigType {
        TICKS,
        PRICE,
        RANGE
    }

    struct RangeConfigParams {
        RangeConfigType rangeConfigType;
        // For TICKS, ticksDown and ticksUp to count from new position opening tick.
        int24 ticksDown;
        int24 ticksUp;
    }

    enum EndTriggerType {
        COUNT,
        TIMESTAMP
    }

    struct EndParams {
        EndTriggerType triggerType;
        uint256 count;
        uint256 timestamp;
    }

    struct RecurringRebalanceParams {
        RangeConfigParams rangeConfig;
        EndParams end;
        bool active;
    }

    struct ScheduledRebalance {
        // Trigger ticks for the next rebalance
        int24 triggerLower;
        int24 triggerUpper;
        // Ticks to count down and up when opening new position
        int24 newTicksDown;
        int24 newTicksUp;
        RecurringRebalanceParams recurring;
        bool initialized;
        uint256 maxGasFeeUsd;
    }

    struct ScheduledCompound {
        bool initialized;
        // Max percent of flashloan fee + gas fee relative to position fees value
        uint256 maxTotalFeePercent;
    }

    struct ScheduledDeleverage {
        int24 triggerLower;
        int24 triggerUpper;
        bool withdrawLiquidity;
        bool initialized;
        uint256 maxGasFeeUsd;
    }

    mapping(address => ScheduledRebalance) public scheduledRebalances;
    mapping(address => ScheduledDeleverage) public scheduledDeleverages;
    mapping(address => ScheduledCompound) public scheduledCompounds;

    function _calculateFeeInPositionDebtToken(address position, uint256 usdGasFee, uint256 percentFee)
        internal
        view
        returns (uint256)
    {
        address debtToken = CLLeveragedPosition(position).borrowedToken();
        uint256 debt = CLLeveragedPosition(position).getDebt();
        IYLDROracle oracle = IYLDROracle(addressesProvider.getPriceOracle());
        uint256 debtTokenPrice = oracle.getAssetPrice(debtToken);

        return (10 ** IERC20Metadata(debtToken).decimals()) * usdGasFee / debtTokenPrice + debt * percentFee / 1e4;
    }

    function _checkPositionOwner(address position) internal view {
        require(CLLeveragedPosition(position).owner() == msg.sender, "Only owner can setup rebalance");
    }

    function setupRebalance(
        address position,
        int24 triggerLower,
        int24 triggerUpper,
        int24 newTicksDown,
        int24 newTicksUp,
        RecurringRebalanceParams memory recurring,
        uint256 maxGasFeeUsd
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
            maxGasFeeUsd: maxGasFeeUsd
        });
    }

    function cancelRebalance(address position) public {
        _checkPositionOwner(position);
        delete scheduledRebalances[position];
    }

    function _canRebalance(address position, int24 currentTick) internal view returns (bool) {
        ScheduledRebalance memory scheduledRebalance = scheduledRebalances[position];
        if (!scheduledRebalance.initialized) {
            return false;
        }
        return (scheduledRebalance.triggerLower >= currentTick) || (scheduledRebalance.triggerUpper <= currentTick);
    }

    function canRebalance(address position) public view returns (bool) {
        (BaseCLAdapter adapter, BaseCLAdapter.PositionData memory data) = _getPositionCLAdapterAndData(position);
        address pool = adapter.getPool(data);
        (, int24 currentTick) = adapter.getPoolState(pool);

        return _canRebalance(position, currentTick);
    }

    function _getNextRebalanceTriggers(
        RecurringRebalanceParams memory recurring,
        int24 currentTick,
        int24 newTickLower,
        int24 newTickUpper
    ) internal view returns (bool ended, int24 triggerLower, int24 triggerUpper) {
        if (!recurring.active) {
            return (true, 0, 0);
        }

        if (recurring.end.triggerType == EndTriggerType.COUNT) {
            recurring.end.count -= 1;
            if (recurring.end.count == 0) {
                return (true, 0, 0);
            }
        } else if (recurring.end.triggerType == EndTriggerType.TIMESTAMP) {
            if (block.timestamp >= recurring.end.timestamp) {
                return (true, 0, 0);
            }
        }

        if (recurring.rangeConfig.rangeConfigType == RangeConfigType.TICKS) {
            return (false, currentTick - recurring.rangeConfig.ticksDown, currentTick + recurring.rangeConfig.ticksUp);
        } else if (recurring.rangeConfig.rangeConfigType == RangeConfigType.RANGE) {
            return (false, newTickLower, newTickUpper);
        }

        return (true, 0, 0);
    }

    function executeRebalance(address position, IERC3156FlashLender flashloanProvider, uint256 usdGasFee) public {
        _checkOwner();

        int24 currentTick;
        int24 tickSpacing;
        {
            (BaseCLAdapter adapter, BaseCLAdapter.PositionData memory data) = _getPositionCLAdapterAndData(position);
            address pool = adapter.getPool(data);
            (, currentTick) = adapter.getPoolState(pool);
            tickSpacing = adapter.getTickSpacing(pool);
        }

        require(_canRebalance(position, currentTick), "Rebalance not allowed");

        ScheduledRebalance memory scheduledRebalance = scheduledRebalances[position];
        require(usdGasFee <= scheduledRebalance.maxGasFeeUsd, "Gas fee too high");

        int24 newTickLower = currentTick - scheduledRebalance.newTicksDown;
        int24 newTickUpper = currentTick + scheduledRebalance.newTicksUp;

        newTickLower -= (tickSpacing + newTickLower % tickSpacing) % tickSpacing;
        newTickUpper += (tickSpacing - newTickUpper % tickSpacing) % tickSpacing;

        uint256 fee =
            _calculateFeeInPositionDebtToken({position: position, usdGasFee: usdGasFee, percentFee: rebalanceFee});

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
        uint256 maxGasFeeUsd
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
            maxGasFeeUsd: maxGasFeeUsd
        });
    }

    function cancelDeleverage(address position) public {
        _checkPositionOwner(position);
        delete scheduledDeleverages[position];
    }

    function canDeleverage(address position) public view returns (bool) {
        ScheduledDeleverage memory scheduledDeleverage = scheduledDeleverages[position];
        if (!scheduledDeleverage.initialized) {
            return false;
        }
        (BaseCLAdapter adapter, BaseCLAdapter.PositionData memory data) = _getPositionCLAdapterAndData(position);
        address pool = adapter.getPool(data);
        (, int24 currentTick) = adapter.getPoolState(pool);
        return (scheduledDeleverage.triggerLower >= currentTick) || (scheduledDeleverage.triggerUpper <= currentTick);
    }

    function executeDeleverage(address position, IERC3156FlashLender flashloanProvider, uint256 usdGasFee) public {
        _checkOwner();
        require(canDeleverage(position), "Deleverage not allowed");

        ScheduledDeleverage memory scheduledDeleverage = scheduledDeleverages[position];
        require(usdGasFee <= scheduledDeleverage.maxGasFeeUsd, "Gas fee too high");

        uint256 fee =
            _calculateFeeInPositionDebtToken({position: position, usdGasFee: usdGasFee, percentFee: deleverageFee});

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
    }

    function cancelCompound(address position) public {
        _checkPositionOwner(position);
        delete scheduledCompounds[position];
    }

    function canCompound(address position) public view returns (bool) {
        ScheduledCompound memory scheduledCompound = scheduledCompounds[position];
        return scheduledCompound.initialized;
    }

    function executeCompound(address position, IERC3156FlashLender flashloanProvider, uint256 usdGasFee) public {
        _checkOwner();
        require(canCompound(position), "Compound not allowed");

        uint256 fee = _calculateAndValidateCompoundFee(
            position, flashloanProvider, usdGasFee, scheduledCompounds[position].maxTotalFeePercent
        );

        CLLeveragedPosition(position).compoundAutomation(
            flashloanProvider,
            CLLeveragedPosition.CompoundParams({assetConverter: assetConverter, maxSwapSlippage: maxSwapSlippage}),
            fee
        );
    }

    function _calculateAndValidateCompoundFee(
        address position,
        IERC3156FlashLender flashLoanProvider,
        uint256 usdGasFee,
        uint256 maxFeePercent
    ) internal view returns (uint256) {
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

        uint256 gasFee = usdGasFee * 10 ** IERC20Metadata(debtToken).decimals() / oracle.getAssetPrice(debtToken);
        uint256 flashFee = flashLoanProvider.flashFee(debtToken, CLLeveragedPosition(position).getDebt() + gasFee);
        uint256 flashFeeUsd = flashFee * oracle.getAssetPrice(debtToken) / 10 ** IERC20Metadata(debtToken).decimals();
        uint256 percent = (flashFeeUsd + usdGasFee) * 1e4 / pendingFeesUsd;

        require(percent <= maxFeePercent, "Fee too high");

        return gasFee;
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
}
