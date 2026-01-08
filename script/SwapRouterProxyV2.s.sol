// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SwapV2RouterProxy} from "../src/SwapV2RouterProxy.sol";

contract DeploySwapRouterProxyHedera is Script {
    function run() external {
        address router = vm.envAddress("SAUCERSWAP_V2_ROUTER_ADDRESS");
        address whbar = vm.envAddress("WHBAR_TOKEN_ADDRESS");

        vm.startBroadcast();

        SwapV2RouterProxy proxy = new SwapV2RouterProxy(router, whbar);

        vm.stopBroadcast();

        console.log("SwapRouterProxy V2 deployed at:", address(proxy));
    }
}
