pragma solidity ^0.8.10;

import {BaseCLAdapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/BaseCLAdapter.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {CLAdapterWrapper} from "@yldr-lending/core/src/protocol/concentrated-liquidity/CLAdapterWrapper.sol";

abstract contract BaseCLTestingUtils is StdCheats {
    using SafeERC20 for IERC20;
    using CLAdapterWrapper for BaseCLAdapter;

    BaseCLAdapter public immutable adapter;

    constructor(BaseCLAdapter _adapter) {
        adapter = _adapter;
    }

    function mintPosition(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired,
        address receiver
    ) public returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        deal(token0, address(this), amount0Desired);
        deal(token1, address(this), amount1Desired);

        IERC20(token0).forceApprove(adapter.getPositionManager(), type(uint256).max);
        IERC20(token1).forceApprove(adapter.getPositionManager(), type(uint256).max);

        // has no effect for non-uniswap
        uint24 fee = 500;

        address pool = adapter.getPool(
            BaseCLAdapter.PositionData({
                tokenId: 0,
                token0: token0,
                token1: token1,
                fee: fee,
                liquidity: 0,
                tickLower: -887272,
                tickUpper: 887272,
                tokensOwed0: 0,
                tokensOwed1: 0,
                feeGrowthInside0LastX128: 0,
                feeGrowthInside1LastX128: 0
            })
        );

        (, int24 tickCurrent) = adapter.getPoolState(pool);
        int24 spacing = adapter.getTickSpacing(pool);

        return adapter.delegateMintPosition(
            BaseCLAdapter.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: (tickCurrent - 500) / spacing * spacing,
                tickUpper: (tickCurrent + 500) / spacing * spacing,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: receiver,
                deadline: type(uint256).max
            })
        );
    }

    function movePoolPrice(address pool, uint160 targetSqrtPriceX96) public {
        _movePoolPrice(pool, targetSqrtPriceX96);
    }

    function movePoolPrice(address pool, int24 tick) public {
        _movePoolPrice(pool, TickMath.getSqrtRatioAtTick(tick));
    }

    function movePoolPrice(uint256 positionTokenId, uint160 targetSqrtPriceX96) public {
        _movePoolPrice(adapter.getPool(adapter.getPositionData(positionTokenId)), targetSqrtPriceX96);
    }

    function movePoolPrice(uint256 positionTokenId, int24 tick) public {
        movePoolPrice(adapter.getPool(adapter.getPositionData(positionTokenId)), tick);
    }

    function _movePoolPrice(address pool, uint160 targetSqrtPriceX96) internal virtual;
}
