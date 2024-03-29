pragma solidity ^0.8.10;

import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {UniswapV3DataProvider, INonfungiblePositionManager} from "../src/ui/UniswapV3DataProvider.sol";

contract UniswapV3DataProviderTest is BaseTest {
    UniswapV3DataProvider public uniswapV3DataProvider;

    function test_mainnet() public {
        vm.createSelectFork("mainnet");
        vm.rollFork(18678509);

        uniswapV3DataProvider =
            new UniswapV3DataProvider(INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));

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

        INonfungiblePositionManager positionManager =
            INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);

        uniswapV3DataProvider = new UniswapV3DataProvider(positionManager);

        uniswapV3DataProvider.getPositionData(1021735);
        uniswapV3DataProvider.getPositionData(1021320);

        vm.rollFork(164914100);
        UniswapV3DataProvider.PositionData memory data = uniswapV3DataProvider.getPositionData(1028069);

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
