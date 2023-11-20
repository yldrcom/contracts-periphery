pragma solidity ^0.8.10;

import {BaseTest} from "@yldr-lending/core/test/base/BaseTest.sol";
import {UniswapV3DataProvider, INonfungiblePositionManager} from "../src/ui/UniswapV3DataProvider.sol";

contract UniswapV3DataProviderTest is BaseTest {
    UniswapV3DataProvider public uniswapV3DataProvider;

    constructor() {
        vm.createSelectFork("mainnet");
        vm.rollFork(18678509);

        uniswapV3DataProvider =
            new UniswapV3DataProvider(INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));
    }

    function test() public {
        uint256[] memory ids = new uint256[](5);
        ids[0] = 108501;
        ids[1] = 111455;
        ids[2] = 614231;
        ids[3] = 614225;
        ids[4] = 614213;

        uniswapV3DataProvider.getPositionsData(ids);
    }
}
