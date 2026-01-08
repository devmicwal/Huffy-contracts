// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PairWhitelist} from "../src/PairWhitelist.sol";

contract DeployPairWhitelist is Script {
    function run() external {
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");
        vm.startBroadcast();
        PairWhitelist pairWhitelist = new PairWhitelist(timelock);
        vm.stopBroadcast();

        console.log("PairWhitelist deployed at:", address(pairWhitelist));
    }
}
