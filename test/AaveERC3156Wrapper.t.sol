pragma solidity 0.8.23;

import {BaseERC3156WrapperTest, IERC3156FlashLender} from "./BaseERC3156WrapperTest.sol";
import {AaveERC3156Wrapper, IPool} from "../src/flashloan/AaveERC3156Wrapper.sol";

contract AaveERC3156WrapperTest is BaseERC3156WrapperTest {
    IPool pool = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    constructor() {
        vm.createSelectFork("arbitrum_one");
        vm.rollFork(185007683);
    }

    function _getAvailableTokens() internal virtual override returns (address[] memory tokens) {
        tokens = new address[](4);
        tokens[0] = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        tokens[1] = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4;
        tokens[2] = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
        tokens[3] = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    }

    function _getWrapper() internal virtual override returns (IERC3156FlashLender lender) {
        lender = new AaveERC3156Wrapper(pool);
    }
}
