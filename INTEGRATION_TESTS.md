## Full Sequence for Testing All Contract Methods

### Start a network with Anvil

```shell
anvil --fork-url https://testnet.hashio.io/api
```

### Setup – Environment Variables

```shell
# GLOBAL
ACCOUNT_ID=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
RPC_URL=127.0.0.1:8545

# Treasury
QUOTE_TOKEN_ADDRESS=0x5bf5b11053e734690269C6B9D438F8C9d48F528A
HTK_TOKEN_ADDRESS=0x3347B4d90ebe72BeFb30444C9966B2B990aE9FcB
SAUCERSWAP_ROUTER=0x3aAde2dCD2Df6a8cAc689EE797591b2913658659
SWAP_ADAPTER_ADDRESS=0xSwapAdapter
MOCK_DAO_ADDRESS=0x1f10F3Ba7ACB61b2F50B9d6DdCf91a6f787C0E82
DAO_ADMIN_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
RELAY_ADDRESS=0xb9bEECD1A582768711dE1EE7B0A1d582D9d72a6C

# Relay
PAIR_WHITELIST_ADDRESS=0x2a810409872AfC346F9B5b26571Fd6eC42EA4849
TREASURY_ADDRESS=0x457cCf29090fe5A24c19c1bc95F492168C0EaFdb
INITIAL_TRADER_ADDRESSES=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
MAX_TRADE_BPS=1000              # 10%
MAX_SLIPPAGE_BPS=500            # 5%
TRADE_COOLDOWN_SEC=60           # 60 seconds

DEADLINE=1918370747

# Adapter paths (bytes-encoded routes for the swap adapter)
USDC_TO_HTK_PATH=0xYourEncodedPathHere
HTK_TO_USDC_PATH=0xYourReversePathHere
USDC_TO_USDC_PATH=0xLoopbackPathForTesting
```

```shell  
  source .env
```
---

## 1. Deploy MockDAO, MockERC20, MockSoucerSwapRouter, MockRelay (will be replaced), Treasury Contract
```shell  
forge script script/DeployMocks.s.sol:DeployMocks --rpc-url 127.0.0.1:8545 --private-key $PRIVATE_KEY --broadcast -vv
```

---

## 2. Deploy PairWhitelist Contract
```shell
forge script script/PairWhitelist.s.sol:DeployPairWhitelist --rpc-url 127.0.0.1:8545 --private-key $PRIVATE_KEY --broadcast -vv
```

---

## 3. Deploy Relay Contract
```shell
forge script script/Relay.s.sol:DeployRelay --rpc-url 127.0.0.1:8545 --private-key $PRIVATE_KEY --broadcast -vv
```

---

## 4. Add USDC/HTK
```shell
cast send $PAIR_WHITELIST_ADDRESS "addPair(address,address)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS --rpc-url 127.0.0.1:8545 --private-key $PRIVATE_KEY
```

---

## 5. Add HTK/USDC
```shell
cast send $PAIR_WHITELIST_ADDRESS "addPair(address,address)" $HTK_TOKEN_ADDRESS $QUOTE_TOKEN_ADDRESS --rpc-url 127.0.0.1:8545 --private-key $PRIVATE_KEY
```

---

## 6. Replace MockRelay with real Relay in Treasury (via MockDAO with DEFAULT_ADMIN_ROLE)
```shell
cast send $MOCK_DAO_ADDRESS "updateRelay(address,address)" 0x38a024C0b412B9d1db8BC398140D00F5Af3093D4 $RELAY_ADDRESS --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

---

## 7. Configure MockSaucerswapRouter Exchange Rates

Note: In the mock router, exchange rates are 1e18-scaled (fixed-point, 18 decimals), independent of token decimals. Tokens may have different decimals (in our mocks HTK has 18 decimals and USDC has 6). Set rates like 0.5e18 and 2e18. Examples:
- 1 HTK = 0.5 USDC → rate = 0.5e18
- 1 USDC = 2 HTK → rate = 2e18

```shell
# Set exchange rate: 1 HTK = 0.5 USDC (rate = 0.5 * 10^18)
cast send $SAUCERSWAP_ROUTER "setExchangeRate(address,address,uint256)" $HTK_TOKEN_ADDRESS $QUOTE_TOKEN_ADDRESS 500000000000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

```shell
# Set exchange rate: 1 USDC = 2 HTK (rate = 2 * 10^18)
cast send $SAUCERSWAP_ROUTER "setExchangeRate(address,address,uint256)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS 2000000000000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

```shell
# Verify exchange rates
cast call $SAUCERSWAP_ROUTER "exchangeRates(address,address)" $HTK_TOKEN_ADDRESS $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
cast call $SAUCERSWAP_ROUTER "exchangeRates(address,address)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL
```

---

## 8. Fund MockSaucerswapRouter with Tokens

```shell
# Approve HTK for router (HTK has 18 decimals)
cast send $HTK_TOKEN_ADDRESS "approve(address,uint256)" $SAUCERSWAP_ROUTER 100000000000000000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

```shell
# Fund router with HTK (100,000 HTK = 100000 * 10^18)
cast send $SAUCERSWAP_ROUTER "fundRouter(address,uint256)" $HTK_TOKEN_ADDRESS 100000000000000000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

```shell
# Approve USDC for router
cast send $QUOTE_TOKEN_ADDRESS "approve(address,uint256)" $SAUCERSWAP_ROUTER 100000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

```shell
# Fund router with USDC (100,000 USDC = 100000 * 10^6)
cast send $SAUCERSWAP_ROUTER "fundRouter(address,uint256)" $QUOTE_TOKEN_ADDRESS 100000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

```shell
# Verify router balances
echo "Router HTK balance:"
cast call $HTK_TOKEN_ADDRESS "balanceOf(address)" $SAUCERSWAP_ROUTER --rpc-url $RPC_URL

echo "Router USDC balance:"
cast call $QUOTE_TOKEN_ADDRESS "balanceOf(address)" $SAUCERSWAP_ROUTER --rpc-url $RPC_URL
```

---

## 9. Check Treasury Balances

```shell
# Check USDC balance in Treasury
cast call $TREASURY_ADDRESS "getBalance(address)" $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
```
```shell
# Check HTK balance in Treasury
cast call $TREASURY_ADDRESS "getBalance(address)" $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL
```

---

## 10. Check Roles in Contracts

```shell
# Check if the new Relay has RELAY_ROLE in Treasury
cast call $TREASURY_ADDRESS "hasRole(bytes32,address)" 0x077a1d526a4ce8a773632ab13b4fbbf1fcc954c3dab26cd27ea0e2a6750da5d7 $RELAY_ADDRESS --rpc-url $RPC_URL
```
```shell
# Check if MockDAO has DEFAULT_ADMIN_ROLE in Treasury
cast call $TREASURY_ADDRESS "hasRole(bytes32,address)" 0x0000000000000000000000000000000000000000000000000000000000000000 $MOCK_DAO_ADDRESS --rpc-url $RPC_URL
```
```shell
# Check if MockDAO has DAO_ROLE in Treasury
cast call $TREASURY_ADDRESS "hasRole(bytes32,address)" 0x3b5d4cc60d3ec3516ee8ae083bd60934f6eb2a6c54b1229985c41bfb092b2603 $MOCK_DAO_ADDRESS --rpc-url $RPC_URL
```
```shell
# Check if trader has TRADER_ROLE in Relay
cast call $RELAY_ADDRESS "hasRole(bytes32,address)" 0x4e6c7e0c7b03dd59adb2b3d8d4d82e5e1e8ef3f9c5e1d8b2a6c3e7f9a1b4d5c6 $ACCOUNT_ID --rpc-url $RPC_URL
```
```shell
# Grant TRADER_ROLE to trader
cast send $RELAY_ADDRESS "grantRole(bytes32,address)" 0x4e6c7e0c7b03dd59adb2b3d8d4d82e5e1e8ef3f9c5e1d8b2a6c3e7f9a1b4d5c6 $ACCOUNT_ID --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

---

## 11. Test PairWhitelist – Check Whitelisted Pairs

```shell
# Check USDC->HTK
cast call $PAIR_WHITELIST_ADDRESS "isPairWhitelisted(address,address)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL
```
```shell
# Check HTK->USDC
cast call $PAIR_WHITELIST_ADDRESS "isPairWhitelisted(address,address)" $HTK_TOKEN_ADDRESS $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
```

---

## 12. Test Relay – Check Risk Parameters

```shell
# Check maxTradeBps (max 10% = 1000 bps)
cast call $RELAY_ADDRESS "maxTradeBps()" --rpc-url $RPC_URL
```
```shell
# Check maxSlippageBps (max 5% = 500 bps)
cast call $RELAY_ADDRESS "maxSlippageBps()" --rpc-url $RPC_URL
```
```shell
# Check tradeCooldownSec (60 seconds)
cast call $RELAY_ADDRESS "tradeCooldownSec()" --rpc-url $RPC_URL
```
```shell
# Check last trade timestamp for trader
cast call $RELAY_ADDRESS "lastTradeTimestamp(address)" $ACCOUNT_ID --rpc-url $RPC_URL
```

---

## 13. Test Relay – Swap USDC->HTK (without burn)

```shell
# Step 1: Check USDC balance in Treasury before swap
echo "USDC before swap:"
cast call $TREASURY_ADDRESS "getBalance(address)" $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
```
```shell
# Step 2: Check HTK balance in Treasury before swap
echo "HTK before swap:"
cast call $TREASURY_ADDRESS "getBalance(address)" $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL
```
```shell
# Step 3: Propose (relay) and Execute (treasury) swap 1000 USDC (6 decimals) -> HTK (18 decimals)
# amountIn = 1000 * 10^6 = 1000000000 (1000 USDC)
# amountOutMin = 1900 * 10^18 = 1900000000000000000000 (1900 HTK with 5% slippage)
cast send $RELAY_ADDRESS "proposeSwap(address,address,bytes,uint256,uint256,uint256)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS $USDC_TO_HTK_PATH 1000000000 1900000000000000000000 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

```shell
# Step 4: Check balances after swap
echo "USDC after swap:"
cast call $TREASURY_ADDRESS "getBalance(address)" $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
```
```shell
echo "HTK after swap:"
cast call $TREASURY_ADDRESS "getBalance(address)" $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL
```

---

## 14. Test Relay – Buyback-and-Burn USDC->HTK

```shell
# Step 1: Check balances before buyback
echo "USDC before buyback:"
cast call $TREASURY_ADDRESS "getBalance(address)" $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
```
```shell
echo "HTK before buyback:"
cast call $TREASURY_ADDRESS "getBalance(address)" $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL
```
```shell
# Step 2: Execute buyback-and-burn 500 USDC -> HTK (burn)
# amountIn = 500 * 10^6 = 500000000 (500 USDC)
# amountOutMin = 950 * 10^18 = 950000000000000000000 (950 HTK with 5% slippage)
cast send $RELAY_ADDRESS "proposeBuybackAndBurn(address,bytes,uint256,uint256,uint256)" $QUOTE_TOKEN_ADDRESS $USDC_TO_HTK_PATH 500000000 950000000000000000000 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
```shell
# Step 3: Check balances after buyback (HTK should be burned – sent to 0xdead)
echo "USDC after buyback:"
cast call $TREASURY_ADDRESS "getBalance(address)" $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
```
```shell
echo "HTK after buyback (should be burned):"
cast call $TREASURY_ADDRESS "getBalance(address)" $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL
```
```shell
# Step 4: Check dead address balance (burned HTK)
cast call $HTK_TOKEN_ADDRESS "balanceOf(address)" 0x000000000000000000000000000000000000dead --rpc-url $RPC_URL
```

---

## 15. Test Relay – Swap HTK->USDC (reverse direction)

```shell
# Note: Relay enforces maxTradeBps (default 10%). The cap is computed on the Treasury's HTK balance.
# You can check the current maximum allowed input for HTK:
cast call $RELAY_ADDRESS "getMaxAllowedTradeAmount(address)" $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL

# Option A (respect 10% cap): swap 200 HTK
# amountIn = 200 * 10^18 = 200000000000000000000 (200 HTK)
# With rate 1 HTK = 0.5 USDC, expected = 100 USDC; with 5% slippage, min = 95 USDC
cast send $RELAY_ADDRESS "proposeSwap(address,address,bytes,uint256,uint256,uint256)" $HTK_TOKEN_ADDRESS $QUOTE_TOKEN_ADDRESS $HTK_TO_USDC_PATH 200000000000000000000 95000000 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Option B (if you want to trade 1000 HTK): temporarily raise the cap via DAO to 50%
# cast send $RELAY_ADDRESS "setMaxTradeBps(uint256)" 5000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
# Then you can use the original 1000 HTK example:
# cast send $RELAY_ADDRESS "proposeSwap(address,address,bytes,uint256,uint256,uint256)" $HTK_TOKEN_ADDRESS $QUOTE_TOKEN_ADDRESS $HTK_TO_USDC_PATH 1000000000000000000000 475000000 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Check balances
echo "HTK balance:"
cast call $TREASURY_ADDRESS "getBalance(address)" $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL

echo "USDC balance:"
echo "(Note: USDC has 6 decimals)"
cast call $TREASURY_ADDRESS "getBalance(address)" $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
```

---

## 16. Test Treasury – Token Deposit by User

```shell
# Step 1: Approve USDC for Treasury (from user account)
cast send $QUOTE_TOKEN_ADDRESS "approve(address,uint256)" $TREASURY_ADDRESS 10000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
```shell
# Step 2: Deposit 10000 USDC into Treasury
cast send $TREASURY_ADDRESS "deposit(address,uint256)" $QUOTE_TOKEN_ADDRESS 10000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
```shell
# Step 3: Check new balance
cast call $TREASURY_ADDRESS "getBalance(address)" $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
```

---

## 17. Test Treasury – Withdraw by DAO

```shell
# Only MockDAO can call withdraw (has DAO_ROLE)

# Step 1: Check balance before withdraw
echo "Treasury USDC before withdraw:"
cast call $TREASURY_ADDRESS "getBalance(address)" $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
```
```shell
# Step 2: Withdraw 1000 USDC by MockDAO to recipient address
cast send $MOCK_DAO_ADDRESS "withdrawFromTreasury(address,address,uint256)" $QUOTE_TOKEN_ADDRESS $ACCOUNT_ID 1000000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
```shell
# Step 3: Check balance after withdraw
echo "Treasury USDC after withdraw:"
cast call $TREASURY_ADDRESS "getBalance(address)" $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
```
```shell
# Step 4: Check recipient balance
cast call $QUOTE_TOKEN_ADDRESS "balanceOf(address)" $ACCOUNT_ID --rpc-url $RPC_URL
```

---

## 18. Test Relay – Manage Traders via DAO

```shell
# Add new trader
NEW_TRADER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

# Grant TRADER_ROLE to new trader
cast send $RELAY_ADDRESS "grantRole(bytes32,address)" 0x4e6c7e0c7b03dd59adb2b3d8d4d82e5e1e8ef3f9c5e1d8b2a6c3e7f9a1b4d5c6 $NEW_TRADER --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Check if trader has the role
cast call $RELAY_ADDRESS "hasRole(bytes32,address)" 0x4e6c7e0c7b03dd59adb2b3d8d4d82e5e1e8ef3f9c5e1d8b2a6c3e7f9a1b4d5c6 $NEW_TRADER --rpc-url $RPC_URL

# Remove trader
cast send $RELAY_ADDRESS "revokeRole(bytes32,address)" 0x4e6c7e0c7b03dd59adb2b3d8d4d82e5e1e8ef3f9c5e1d8b2a6c3e7f9a1b4d5c6 $NEW_TRADER --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

---

## 19. Test Relay – Update Risk Parameters via DAO

```shell
# Update maxTradeBps to 2000 (20%)
cast send $RELAY_ADDRESS "setMaxTradeBps(uint256)" 2000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Check new value
cast call $RELAY_ADDRESS "maxTradeBps()" --rpc-url $RPC_URL

# Update maxSlippageBps to 1000 (10%)
cast send $RELAY_ADDRESS "setMaxSlippageBps(uint256)" 1000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Check new value
cast call $RELAY_ADDRESS "maxSlippageBps()" --rpc-url $RPC_URL

# Update tradeCooldownSec to 120 seconds
cast send $RELAY_ADDRESS "setTradeCooldownSec(uint256)" 120 --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Check new value
cast call $RELAY_ADDRESS "tradeCooldownSec()" --rpc-url $RPC_URL
```

---

## 20. Test PairWhitelist – Remove Pair from Whitelist

```shell
# Blacklist USDC->HTK pair
cast send $PAIR_WHITELIST_ADDRESS "removePair(address,address)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Check if removed
cast call $PAIR_WHITELIST_ADDRESS "isPairWhitelisted(address,address)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL

# Attempt swap on blacklisted pair (should fail)
cast send $RELAY_ADDRESS "proposeSwap(address,address,bytes,uint256,uint256,uint256)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS $USDC_TO_HTK_PATH 1000000000 1900000000000000000000 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# Restore pair to whitelist
cast send $PAIR_WHITELIST_ADDRESS "addPair(address,address)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

---

## 21. Test PairWhitelist – Multiple Adds (batch removed)

```shell
# Add multiple pairs by calling addPair repeatedly
# Example: USDC->HTK, HTK->USDC
cast send $PAIR_WHITELIST_ADDRESS "addPair(address,address)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL --private-key $PRIVATE_KEY
cast send $PAIR_WHITELIST_ADDRESS "addPair(address,address)" $HTK_TOKEN_ADDRESS $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

---

## 22. Test Error Scenarios

```shell
# Test 1: Attempt trade without TRADER_ROLE (should fail)
UNAUTHORIZED_USER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
cast send $RELAY_ADDRESS "proposeSwap(address,address,bytes,uint256,uint256,uint256)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS $USDC_TO_HTK_PATH 1000000000 1900000000000000000000 $DEADLINE --rpc-url $RPC_URL --private-key 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
# Expected: AccessControlUnauthorizedAccount

# Test 2: Attempt swap on non-whitelisted pair
cast send $RELAY_ADDRESS "proposeSwap(address,address,bytes,uint256,uint256,uint256)" $QUOTE_TOKEN_ADDRESS $QUOTE_TOKEN_ADDRESS $USDC_TO_USDC_PATH 1000000000 1000000000 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY
# Expected: Relay: Pair not whitelisted

# Test 3: Attempt trade before cooldown
cast send $RELAY_ADDRESS "proposeSwap(address,address,bytes,uint256,uint256,uint256)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS $USDC_TO_HTK_PATH 1000000000 1900000000000000000000 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY
# Immediately after:
cast send $RELAY_ADDRESS "proposeSwap(address,address,bytes,uint256,uint256,uint256)" $HTK_TOKEN_ADDRESS $QUOTE_TOKEN_ADDRESS $HTK_TO_USDC_PATH 1000000000000000000000 475000000 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY
# Expected: Relay: Cooldown active

# Test 4: Attempt to exceed maxTradeBps
# If Treasury has 100,000 USDC, max trade = 10% = 10,000 USDC
cast send $RELAY_ADDRESS "proposeSwap(address,address,bytes,uint256,uint256,uint256)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS $USDC_TO_HTK_PATH 20000000000 1 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY
# Expected: Relay: Trade amount exceeds limit
```

---

## 23. Event Monitoring

```shell
# Fetch all events from Treasury
cast logs --address $TREASURY_ADDRESS --from-block 0 --rpc-url $RPC_URL

# Fetch RelayUpdated events
cast logs --address $TREASURY_ADDRESS --from-block 0 "RelayUpdated(address,address,uint256)" --rpc-url $RPC_URL

# Fetch BuybackExecuted events
cast logs --address $TREASURY_ADDRESS --from-block 0 "BuybackExecuted(address,uint256,uint256,address,uint256)" --rpc-url $RPC_URL

# Fetch events from Relay
cast logs --address $RELAY_ADDRESS --from-block 0 --rpc-url $RPC_URL

# Fetch events from PairWhitelist
cast logs --address $PAIR_WHITELIST_ADDRESS --from-block 0 --rpc-url $RPC_URL
```
