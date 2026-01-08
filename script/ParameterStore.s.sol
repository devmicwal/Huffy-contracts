// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ParameterStore} from "../src/ParameterStore.sol";

contract ParameterStoreDeploy is Script {
    function run() external returns (ParameterStore store) {
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");
        uint256 maxTradeBps = vm.envOr("MAX_TRADE_BPS", uint256(1));
        uint256 maxSlippageBps = vm.envOr("MAX_SLIPPAGE_BPS", uint256(2));
        uint256 tradeCooldownSec = vm.envOr("TRADE_COOLDOWN_SEC", uint256(3));

        vm.startBroadcast();
        store = new ParameterStore(timelock, maxTradeBps, maxSlippageBps, tradeCooldownSec);
        vm.stopBroadcast();

        console.log("ParameterStore deployed at", address(store));
        console.log("Timelock:", timelock);
        console.log("Initial params:", maxTradeBps, maxSlippageBps, tradeCooldownSec);

        return store;
    }
}
