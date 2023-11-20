pragma solidity ^0.8.10;

import {PoolTesting} from "@yldr-lending/core/test/libraries/PoolTesting.sol";
import {UniswapV3Testing} from "@yldr-lending/core/test/libraries/UniswapV3Testing.sol";
import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {ERC1155UniswapV3Wrapper} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155UniswapV3Wrapper.sol";
import {ERC1155UniswapV3ConfigurationProvider} from
    "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155UniswapV3ConfigurationProvider.sol";
import {ERC1155UniswapV3Oracle} from "@yldr-lending/core/src/protocol/concentrated-liquidity/ERC1155UniswapV3Oracle.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UniswapV3Leverage, UniswapV3LeveragedPosition} from "../src/leverage/UniswapV3Leverage.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPool} from "@yldr-lending/core/src/interfaces/IPool.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {UniswapV3DepositZap} from "../src/UniswapV3DepositZap.sol";
import {INToken} from "@yldr-lending/core/src/interfaces/INToken.sol";

contract UniswapV3DepositZapTest is BaseTest {
    using PoolTesting for PoolTesting.Data;
    using UniswapV3Testing for UniswapV3Testing.Data;
    using SafeERC20 for IERC20Metadata;

    IERC20Metadata usdc = IERC20Metadata(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Metadata weth = IERC20Metadata(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    PoolTesting.Data poolTesting;
    UniswapV3Testing.Data uniswapV3Testing;

    ERC1155UniswapV3Wrapper uniswapV3Wrapper;
    UniswapV3Leverage uniswapV3Leverage;

    UniswapV3DepositZap zap;

    constructor() {
        vm.createSelectFork("mainnet");
        vm.rollFork(18630167);

        _addAndDealToken(usdc);
        _addAndDealToken(weth);

        uniswapV3Testing.init(INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));

        uniswapV3Wrapper = ERC1155UniswapV3Wrapper(
            address(
                new TransparentUpgradeableProxy(
                    address(new ERC1155UniswapV3Wrapper()),
                    ADMIN,
                    abi.encodeCall(ERC1155UniswapV3Wrapper.initialize, (uniswapV3Testing.positionManager))
                )
            )
        );

        vm.startPrank(ADMIN);
        poolTesting.init(ADMIN, 2);

        poolTesting.addReserve(
            address(usdc), 0.8e27, 0, 0.02e27, 0.8e27, 0.7e4, 0.75e4, 1.05e4, 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6
        );
        poolTesting.addReserve(
            address(weth), 0.8e27, 0, 0.02e27, 0.8e27, 0.7e4, 0.75e4, 1.05e4, 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
        );

        poolTesting.addERC1155Reserve(
            address(uniswapV3Wrapper),
            address(
                new ERC1155UniswapV3ConfigurationProvider(
                    IPool(poolTesting.addressesProvider.getPool()), uniswapV3Wrapper
                )
            ),
            address(new ERC1155UniswapV3Oracle(poolTesting.addressesProvider, uniswapV3Wrapper))
        );

        zap = new UniswapV3DepositZap(poolTesting.addressesProvider, uniswapV3Wrapper);

        vm.startPrank(ALICE);
    }

    function test() public {
        (uint256 tokenId,,) = uniswapV3Testing.acquireUniswapPosition(
            address(usdc), address(weth), 2000e6, 1e18, UniswapV3Testing.PositionType.Both
        );

        uniswapV3Testing.positionManager.safeTransferFrom(ALICE, address(zap), tokenId);

        assertEq(uniswapV3Testing.positionManager.ownerOf(tokenId), address(uniswapV3Wrapper));
        uint256 balance = INToken(zap.nToken()).balanceOf(ALICE, tokenId);
        assertGt(balance, 0);

        INToken(zap.nToken()).safeTransferFrom(ALICE, address(zap), tokenId, balance, "");
        assertEq(uniswapV3Testing.positionManager.ownerOf(tokenId), ALICE);
    }
}
