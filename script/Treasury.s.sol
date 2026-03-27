// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Treasury} from "../src/Treasury.sol";

contract DeployTreasury is Script {
    function run() external {
        address htkToken = vm.envAddress("HTK_TOKEN_ADDRESS");
        address quoteToken = vm.envAddress("QUOTE_TOKEN_ADDRESS");
        address swapAdapter = vm.envOr("SWAP_ADAPTER_ADDRESS", address(0));
        address daoAdmin = vm.envOr("DAO_ADMIN_ADDRESS", msg.sender);
        address relay = vm.envOr("RELAY_ADDRESS", msg.sender);
        address burnSink = vm.envOr("BURN_SINK_ADDRESS", address(0xdead));

        require(htkToken != address(0), "HTK_TOKEN_ADDRESS not set");
        require(quoteToken != address(0), "QUOTE_TOKEN_ADDRESS not set");
        require(swapAdapter != address(0), "SWAP_ADAPTER_ADDRESS not set");
        require(daoAdmin != address(0), "DAO_ADMIN_ADDRESS not set");
        require(relay != address(0), "RELAY_ADDRESS not set");
        require(burnSink != address(0), "BURN_SINK_ADDRESS not set");
        address whbar = vm.envAddress("WHBAR_TOKEN_ADDRESS");
        require(whbar != address(0), "WHBAR_TOKEN_ADDRESS not set");

        console.log("Deployer:", msg.sender);
        console.log("HTK Token:", htkToken);
        console.log("Quote Token:", quoteToken);
        console.log("Swap Adapter:", swapAdapter);
        console.log("DAO Admin:", daoAdmin);
        console.log("Relay:", relay);
        console.log("Burn sink:", burnSink);
        console.log("WHBAR:", whbar);

        vm.startBroadcast();

        Treasury treasury =
            new Treasury(htkToken, quoteToken, swapAdapter, daoAdmin, relay, burnSink, whbar);

        vm.stopBroadcast();

        console.log("Treasury deployed at:", address(treasury));
    }
}
