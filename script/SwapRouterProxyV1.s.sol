// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SwapV1RouterProxy} from "../src/SwapV1RouterProxy.sol";

contract DeploySwapRouterProxyV1 is Script {
    function run() external {
        address router = vm.envAddress("SAUCERSWAP_V1_ROUTER_ADDRESS");
        address whbar = vm.envAddress("WHBAR_TOKEN_ADDRESS");

        vm.startBroadcast();

        SwapV1RouterProxy proxy = new SwapV1RouterProxy(router, whbar);

        vm.stopBroadcast();

        console.log("SwapRouterProxy V1 deployed at:", address(proxy));
    }
}
