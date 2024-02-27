pragma solidity 0.8.23;

import {BaseERC3156WrapperTest, IERC3156FlashLender} from "./BaseERC3156WrapperTest.sol";
import {UniswapV3ERC3156Wrapper, IUniswapV3Pool} from "../src/flashloan/UniswapV3ERC3156Wrapper.sol";

contract UniswapV3ERC3156WrapperTest is BaseERC3156WrapperTest {
    IUniswapV3Pool pool = IUniswapV3Pool(0xC31E54c7a869B9FcBEcc14363CF510d1c41fa443);

    constructor() {
        vm.createSelectFork("arbitrum_one");
        vm.rollFork(185007683);
    }

    function _getAvailableTokens() internal virtual override returns (address[] memory) {
        address[] memory tokens = new address[](2);
        tokens[0] = pool.token0();
        tokens[1] = pool.token1();
        return tokens;
    }

    function _getWrapper() internal virtual override returns (IERC3156FlashLender lender) {
        lender = new UniswapV3ERC3156Wrapper(pool);
    }
}
