// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockSaucerswapRouter} from "../src/mocks/MockSaucerswapRouter.sol";
import {MockSwapAdapter} from "../src/mocks/MockSwapAdapter.sol";
import {MockDAO} from "../src/mocks/MockDAO.sol";
import {MockRelay} from "../src/mocks/MockRelay.sol";
import {Treasury} from "../src/Treasury.sol";

contract DeployMocks is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // 1. Deploy Mock Tokens
        MockERC20 htkToken = new MockERC20("HTK Token", "HTK", 18);
        MockERC20 usdcToken = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 whbarToken = new MockERC20("Wrapped HBAR", "WHBAR", 8);

        // Mint initial supplies to the deployer
        htkToken.mint(msg.sender, 10_000_000e18);
        usdcToken.mint(msg.sender, 1_000_000e6);
        whbarToken.mint(msg.sender, 1_000_000e8);

        // 2. Deploy Mock Router (Saucerswap)
        MockSaucerswapRouter router = new MockSaucerswapRouter();
        
        // Setup initial liquidity for HTK and exchange rates on mock router
        htkToken.mint(address(router), 5_000_000e18);
        uint256 exchangeRate = 2e18; // 1 USDC = 2 HTK example rate
        router.setExchangeRate(address(usdcToken), address(htkToken), exchangeRate);

        // 3. Deploy Mock Swap Adapter wrapping the Mock Router
        MockSwapAdapter swapAdapter = new MockSwapAdapter(address(router));

        // 4. Deploy Mock DAO
        MockDAO mockDao = new MockDAO();

        // 5. Deploy Treasury first with dummy relay (msg.sender)
        Treasury treasury = new Treasury(
            address(htkToken),
            address(usdcToken),
            address(swapAdapter),
            address(mockDao),
            msg.sender,        // Temporary relay
            address(0xdead),   // burnSink
            address(whbarToken)
        );

        // 6. Deploy Mock Relay giving it the Treasury address
        MockRelay mockRelay = new MockRelay(payable(address(treasury)));

        // 7. Configure DAO and Update Treasury's relay to the true MockRelay
        mockDao.setTreasury(payable(address(treasury)));
        mockDao.updateRelay(msg.sender, address(mockRelay));
        
        vm.stopBroadcast();

        console.log("=== Mock Environment Deployed Successfully ===");
        console.log("HTK Token:       ", address(htkToken));
        console.log("USDC Token:      ", address(usdcToken));
        console.log("WHBAR Token:     ", address(whbarToken));
        console.log("Mock Router:     ", address(router));
        console.log("Mock SwapAdapter:", address(swapAdapter));
        console.log("Mock DAO:        ", address(mockDao));
        console.log("Treasury:        ", address(treasury));
        console.log("Mock Relay:      ", address(mockRelay));
    }
}
