pragma solidity ^0.8.10;

import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {CLDataProvider} from "../src/ui/CLDataProvider.sol";
import {BaseCLAdapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/BaseCLAdapter.sol";
import {UniswapV3Adapter} from "@yldr-lending/core/src/protocol/concentrated-liquidity/adapters/UniswapV3Adapter.sol";

contract CLDataProviderTest is BaseTest {
    CLDataProvider public uniswapV3DataProvider;
    INonfungiblePositionManager positionManager =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

    function test_mainnet() public {
        vm.createSelectFork("mainnet");
        vm.rollFork(18678509);

        UniswapV3Adapter adapter = new UniswapV3Adapter(address(positionManager));
        uniswapV3DataProvider = new CLDataProvider(adapter);

        uint256[] memory ids = new uint256[](5);
        ids[0] = 108501;
        ids[1] = 111455;
        ids[2] = 614231;
        ids[3] = 614225;
        ids[4] = 614213;

        uniswapV3DataProvider.getPositionsData(ids);
    }

    function test_arbitrum() public {
        vm.createSelectFork("arbitrum_one");
        vm.rollFork(163870012);

        UniswapV3Adapter adapter = new UniswapV3Adapter(address(positionManager));
        uniswapV3DataProvider = new CLDataProvider(adapter);

        uniswapV3DataProvider.getPositionData(1021735);
        uniswapV3DataProvider.getPositionData(1021320);

        vm.rollFork(164914100);
        CLDataProvider.CLPositionData memory data = uniswapV3DataProvider.getPositionData(1028069);

        vm.startPrank(positionManager.ownerOf(1028069));
        (uint256 received0, uint256 received1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: 1028069,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        assertEq(data.fee0, received0);
        assertEq(data.fee1, received1);
    }
}
