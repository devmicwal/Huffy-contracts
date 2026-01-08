// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockSaucerswapRouter} from "../src/mocks/MockSaucerswapRouter.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract SaucerswapMock is Script {
    function run() external {
        address htkToken = vm.envAddress("HTK_TOKEN_ADDRESS");
        address usdcToken = vm.envAddress("QUOTE_TOKEN_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        require(htkToken != address(0), "HTK_TOKEN_ADDRESS not set");
        require(usdcToken != address(0), "QUOTE_TOKEN_ADDRESS not set");
        require(deployerKey != 0, "PRIVATE_KEY not set");

        vm.startBroadcast(deployerKey);
        MockSaucerswapRouter router = new MockSaucerswapRouter();
        vm.stopBroadcast();

        console.log("Mock Saucerswap Router deployed at:", address(router));

        MockERC20 htk = MockERC20(htkToken);
        MockERC20 usdc = MockERC20(usdcToken);

        vm.startBroadcast(deployerKey);
        uint256 routerHtkSupply = 5_000_000e18;
        htk.mint(address(router), routerHtkSupply);

        uint256 exchangeRate = 2e18;
        router.setExchangeRate(address(usdc), address(htk), exchangeRate);
        vm.stopBroadcast();

        console.log("Funded router with HTK and set exchange rate 1 USDC = 2 HTK");
    }
}
