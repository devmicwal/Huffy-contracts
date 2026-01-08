# Hedera Testnet: Deploy Treasury and Mocks, and Run Operations

This project includes a Treasury contract that can hold tokens, execute buyback-and-burn operations via the Saucerswap router, perform generic token swaps, and allow DAO-controlled withdrawals.

Important context from the code:
- Treasury constructor: `Treasury(address htkToken, address swapAdapter, address daoAdmin, address relay)`
- Roles:
  - `DEFAULT_ADMIN_ROLE` and `DAO_ROLE` are given to `daoAdmin` at deploy time.
  - `RELAY_ROLE` is given to `relay` at deploy time; only the relay can call swap and buyback.
- Swaps route directly through an `ISwapAdapter` set on Treasury; the DAO can update the adapter via `setAdapter(address)`.
- Mocks: `MockERC20`, `MockSaucerswapRouter` (with settable exchange rates), `MockDAO` (acts as DAO admin), and `MockRelay` (to invoke Treasury methods).

To change adapters in production, the DAO calls `setAdapter(address)` on Treasury:
```
cast send $TREASURY_ADDRESS "setAdapter(address)" $NEW_ADAPTER --rpc-url $RPC_URL --private-key $DAO_ADMIN_PRIVATE_KEY
```

Important script roles:
- script/DeployMocks.s.sol: Deploys a full testing environment on testnet, including mocks AND a Treasury instance wired to the mock router. Use this to prepare contracts and addresses for end-to-end testing.
- script/Treasury.s.sol: Production deployment script for the real Treasury on testnet/mainnet with your real token/router/admin/relay settings.

## Prerequisites

- Foundry installed (forge, cast)
- Hedera Testnet RPC URL and a funded testnet account private key
  - Example RPC providers: HashIO

Optional but recommended:
- Create a `.env` file in the project root so `forge` and scripts can load variables automatically.

Example `.env` values (placeholders):
```
HEDERA_RPC_URL=https://your-hedera-testnet-rpc
PRIVATE_KEY=0xabc... # your deployer account private key
# Used by script/Treasury.s.sol
HTK_TOKEN_ADDRESS=0xYourHTKTokenAddressOnTestnet
SAUCERSWAP_ROUTER=0x00000000000000000000000000000000001A9B39  # default in script (Hedera Testnet router)
DAO_ADMIN_ADDRESS=0xYourDaoAdminEvmAddress
RELAY_ADDRESS=0xYourRelayEvmAddress   # can be your deployer for initial testing
```

Note: The Treasury deployment script uses a default Saucerswap Testnet router address if `SAUCERSWAP_ROUTER` isn't provided. You can override via env var if needed.

## 1) Deploy Mocks to Hedera Testnet (testing environment preparation)

If you don't have real tokens or prefer a fully controlled environment on testnet, deploy mocks. This will deploy:
- Mock HTK (18 decimals)
- Mock USDC (6 decimals)
- Mock Saucerswap Router and seed it with HTK
- Mock DAO (admin) and use it as the Treasury DAO admin
- Treasury wired to the mock router (admin = MockDAO, temporary relay = deployer)
- Mock Relay and assign it as the Treasury relay (updated by MockDAO)

Command:
```
source .env
forge script script/DeployMocks.s.sol:DeployMocks --rpc-url RPC_URL --private-key PRIVATE_KEY --broadcast -vv
```
After completion, the script prints and saves addresses to `deployments/mocks-*.json`.

Keep handy:
- HTK token address
- USDC token address
- Mock router address
- Mock DAO address (admin of Treasury)
- Treasury address
- Mock Relay address (has the relay role on Treasury)

## 2) Deploy the real Treasury on Hedera Testnet (production deployment script)

Use an existing HTK token and the testnet Saucerswap router (or your own), set DAO and Relay addresses.

Command
```
forge script script/Treasury.s.sol:DeployTreasury --rpc-url $env:RPC_URL --private-key $env:PRIVATE_KEY --broadcast -vv
```
The script prints and saves deployment info to `deployments/treasury-*.json`.

Tip: If you plan to use a dedicated Relay contract later, you can initially set `RELAY_ADDRESS` to the deployer, deploy a `MockRelay` or your real relay, and then call `updateRelay(oldRelay, newRelay)` from the DAO admin.

## 3) Operations walkthrough

In the following examples:
- Replace addresses and amounts with your own.
- Approvals are required before the Treasury or Router can move tokens.
- Deadlines are UNIX timestamps (seconds). You can use a value about an hour in the future.

We'll use `cast` to submit transactions with the deployer's private key. You can also use other wallets.

### A) Deposit tokens into Treasury

1) Approve the Treasury to pull tokens from your wallet:
```
cast send $QUOTE_TOKEN_ADDRESS "approve(address,uint256)" $TREASURY_ADDRESS 100000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
2) Call deposit on Treasury:
```
cast send $TREASURY_ADDRESS "deposit(address,uint256)" $QUOTE_TOKEN_ADDRESS 100000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
Notes:
- For USDC with 6 decimals, `100000000` = 100 USDC.
- Check balance held by Treasury:
```
cast call $TREASURY_ADDRESS "getBalance(address)(uint256)" $QUOTE_TOKEN_ADDRESS --rpc-url $RPC_URL
```

### B) Withdraw tokens from Treasury (DAO only)

Only an account with `DAO_ROLE` can call `withdraw`.
```
# From DAO admin account (use its private key)
cast send $TREASURY_ADDRESS "withdraw(address,address,uint256)" $QUOTE_TOKEN_ADDRESS 0xRecipient 50000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
This withdraws 50 USDC (6 decimals) to `0xRecipient`.

If you deployed mocks and are using the MockDAO as admin, call via the MockDAO contract from the owner account:
```
cast send $DAO_ADMIN_ADDRESS "withdrawFromTreasury(address,address,uint256)" $QUOTE_TOKEN_ADDRESS 0xRecipient 50000000 --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

### C) Buyback-and-Burn HTK via Saucerswap (Relay only)

Only an account with `RELAY_ROLE` can call `executeBuybackAndBurn`. You may invoke it directly on Treasury (if your caller has the role) or through `MockRelay` which forwards the call.

Direct call (caller must have `RELAY_ROLE`):
```
# Swap 100 USDC for HTK and burn the HTK received (provide an encoded swap path)
cast send $TREASURY_ADDRESS "executeBuybackAndBurn(address,bytes,uint256,uint256,uint256)" $QUOTE_TOKEN_ADDRESS $USDC_TO_HTK_PATH 100000000 0 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
Via MockRelay (recommended during testing):
```
cast send $RELAY "executeBuybackAndBurn(address,bytes,uint256,uint256,uint256)" $QUOTE_TOKEN_ADDRESS $USDC_TO_HTK_PATH 100000000 0 DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
Notes:
- Ensure the Treasury holds enough `tokenIn` (e.g., USDC) before calling.
- `$USDC_TO_HTK_PATH` should contain the adapter-specific bytes-encoded path for the swap route.
- `amountOutMin` can be set to 0 for testing, or a slippage-protected minimum.
- The burn is implemented by transferring HTK to the `0xdead` address and emits `Burned(amount, initiator, timestamp)`.

### D) Generic trade-swap without burning (Relay only)

Use `executeSwap(tokenIn, tokenOut, path, amountIn, amountOutMin, deadline)` to swap and keep proceeds in the Treasury.

Direct call on Treasury (requires `RELAY_ROLE`):
```
# Example: swap USDC -> HTK
cast send $TREASURY_ADDRESS "executeSwap(address,address,bytes,uint256,uint256,uint256)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS $USDC_TO_HTK_PATH 100000000 0 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
Via MockRelay:
```
cast send $RELAY_ADDRESS "executeSwap(address,address,bytes,uint256,uint256,uint256)" $QUOTE_TOKEN_ADDRESS $HTK_TOKEN_ADDRESS $USDC_TO_HTK_PATH 100000000 0 $DEADLINE --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```
Check the Treasury's balances after the swap:
```
cast call $TREASURY_ADDRESS "getBalance(address)(uint256)" $HTK_TOKEN_ADDRESS --rpc-url $RPC_URL
```

## 4) Managing the Relay

To change the relay after deployment, the DAO admin calls `updateRelay(oldRelay, newRelay)`:
```
cast send $TREASURY_ADDRESS "updateRelay(address,address)" 0xOldRelay 0xNewRelay --rpc-url $RPC_URL --private-key 0xDaoAdminPrivateKey
```

## 5) Notes and Troubleshooting

- Approvals: Before swapping, the Treasury approves the router internally for the specific `amountIn`. You only need to ensure the Treasury actually holds the `tokenIn` (via deposit or funding) — users must approve the Treasury before depositing.
- Deadlines: Use a UNIX timestamp in the future; expired deadlines will revert.
- Slippage: Use a sensible `amountOutMin` on testnet vs. setting it to 0 for simplicity.
- Hedera Token Service (HTS): On Hedera EVM, HTS tokens mapped to ERC-20 behave like standard ERC-20 for approvals/transfers in this repo's context.
- Explorers: Use HashScan Testnet to look up addresses and verify events like `Deposited`, `Withdrawn`, `BuybackExecuted`, `SwapExecuted`, and `Burned`.
