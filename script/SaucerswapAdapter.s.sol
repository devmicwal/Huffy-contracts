// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SaucerswapAdapter} from "../src/adapters/SaucerswapAdapter.sol";

contract DeploySaucerswapAdapter is Script {
    function run() external {
        address proxy_v1 = vm.envAddress("SWAP_ROUTER_PROXY_V1_ADDRESS");

        address proxy_v2 = vm.envAddress("SWAP_ROUTER_PROXY_V2_ADDRESS");

        console.log("Deployer:", msg.sender);
        console.log("Swap Router Proxy V1:", proxy_v1);
        console.log("Swap Router Proxy V2:", proxy_v2);

        vm.startBroadcast();

        SaucerswapAdapter adapter = new SaucerswapAdapter(payable(proxy_v2), payable(proxy_v1));

        vm.stopBroadcast();

        console.log("SaucerswapAdapter deployed at:", address(adapter));
    }
}
