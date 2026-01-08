# Hedera Testnet: Deploy and Test Relay Contract

This guide covers deploying and testing the Relay contract, which enforces DAO-controlled risk parameters and validates all trades before forwarding them to the Treasury.

## Overview

The Relay contract acts as a gatekeeper between authorized traders (e.g., HuffyPuppet) and the Treasury. It validates every trade against:
- **PairWhitelist**: Only DAO-approved trading pairs are allowed
- **maxTradeBps**: Maximum trade size as a percentage of Treasury balance
- **maxSlippageBps**: Maximum allowed slippage tolerance
- **tradeCooldownSec**: Minimum time between consecutive trades
- **Trader Authorization**: Only allowlisted traders can submit trades

## Architecture

```
Trader (HuffyPuppet) → Relay (validation) → Treasury (execution) → Saucerswap
                              ↓
                        PairWhitelist
```

## Prerequisites

Same as Treasury testing:
- Foundry installed (forge, cast)
- Hedera Testnet RPC URL and funded account
- `.env` file configured

Additional environment variables for Relay:
```
PAIR_WHITELIST_ADDRESS=0xYourPairWhitelistAddress
TREASURY_ADDRESS=0xYourTreasuryAddress
INITIAL_TRADER_ADDRESS=0xYourHuffyPuppetAddress
MAX_TRADE_BPS=1000              # 10% of Treasury balance
MAX_SLIPPAGE_BPS=500            # 5% slippage tolerance
TRADE_COOLDOWN_SEC=60           # 60 seconds between trades
```

## 1) Deploy PairWhitelist Contract

The PairWhitelist manages which token pairs can be traded.

Command:
```bash
forge create src/PairWhitelist.sol:PairWhitelist \
  --constructor-args $DAO_ADMIN_ADDRESS \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

Save the deployed address as `PAIR_WHITELIST_ADDRESS`.

## 2) Deploy Relay Contract

Deploy with initial risk parameters:

```bash
forge create src/Relay.sol:Relay \
  --constructor-args \
    $PAIR_WHITELIST_ADDRESS \
    $TREASURY_ADDRESS \
    $DAO_ADMIN_ADDRESS \
    $INITIAL_TRADER_ADDRESS \
    1000 \
    500 \
    60 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY
```

Constructor parameters:
1. PairWhitelist address
2. Treasury address
3. DAO admin address
4. Initial trader address (HuffyPuppet)
5. maxTradeBps (1000 = 10%)
6. maxSlippageBps (500 = 5%)
7. tradeCooldownSec (60 seconds)

Save the deployed address as `RELAY_ADDRESS`.

## 3) Update Treasury Relay Role

Grant the Relay contract the `RELAY_ROLE` on Treasury:

```bash
# From DAO admin account
cast send $TREASURY_ADDRESS "updateRelay(address,address)" \
  $OLD_RELAY_ADDRESS \
  $RELAY_ADDRESS \
  --rpc-url $RPC_URL \
  --private-key $DAO_ADMIN_PRIVATE_KEY
```

## 4) Configure PairWhitelist

Whitelist trading pairs that the DAO approves:

### A) Whitelist a Single Pair

```bash
# From DAO admin account
# Example: Allow USDC -> HTK trades
cast send $PAIR_WHITELIST_ADDRESS "addPair(address,address)" \
  $QUOTE_TOKEN_ADDRESS \
  $HTK_TOKEN_ADDRESS \
  --rpc-url $RPC_URL \
  --private-key $DAO_ADMIN_PRIVATE_KEY
```

### B) Whitelist Multiple Pairs (batch removed)

```bash
# From DAO admin account, call addPair repeatedly
cast send $PAIR_WHITELIST_ADDRESS "addPair(address,address)" \
  $QUOTE_TOKEN_ADDRESS \
  $HTK_TOKEN_ADDRESS \
  --rpc-url $RPC_URL \
  --private-key $DAO_ADMIN_PRIVATE_KEY

cast send $PAIR_WHITELIST_ADDRESS "addPair(address,address)" \
  $USDT_TOKEN_ADDRESS \
  $HTK_TOKEN_ADDRESS \
  --rpc-url $RPC_URL \
  --private-key $DAO_ADMIN_PRIVATE_KEY
```

### C) Check if Pair is Whitelisted

```bash
cast call $PAIR_WHITELIST_ADDRESS "isPairWhitelisted(address,address)(bool)" \
  $QUOTE_TOKEN_ADDRESS \
  $HTK_TOKEN_ADDRESS \
  --rpc-url $RPC_URL
```

## 5) Trade Operations

### A) Propose Swap (Trader Only)

Only authorized traders can submit trades:

```bash
# From trader account (HuffyPuppet)
cast send $RELAY_ADDRESS "proposeSwap(address,address,bytes,uint256,uint256,uint256)" \
  $QUOTE_TOKEN_ADDRESS \
  $USDT_TOKEN_ADDRESS \
  $USDC_TO_USDT_PATH \
  100000000 \
  95000000 \
  $DEADLINE \
  --rpc-url $RPC_URL \
  --private-key $TRADER_PRIVATE_KEY
```

Parameters:
- tokenIn: Input token address
- tokenOut: Output token address
- path: Adapter-specific encoded bytes path describing the swap route
- amountIn: Amount to swap (e.g., 100 USDC = 100000000 with 6 decimals)
- minAmountOut: Minimum expected output (accounting for slippage)
- deadline: UNIX timestamp

### B) Propose Buyback and Burn (Trader Only)

```bash
# From trader account
cast send $RELAY_ADDRESS "proposeBuybackAndBurn(address,bytes,uint256,uint256,uint256)" \
  $QUOTE_TOKEN_ADDRESS \
  $USDC_TO_HTK_PATH \
  100000000 \
  190000000000000000000 \
  $DEADLINE \
  --rpc-url $RPC_URL \
  --private-key $TRADER_PRIVATE_KEY
```

Parameters:
- tokenIn: Input token address (e.g., USDC)
- path: Adapter-specific bytes path for the trade
- amountIn: Amount to swap (e.g., 100 USDC)
- minAmountOut: Minimum HTK expected (e.g., 190 HTK with 18 decimals)
- deadline: UNIX timestamp

## 6) Manage Risk Parameters (DAO Only)

### A) Update Max Trade Size

```bash
# From DAO admin account
# Set to 20% (2000 basis points)
cast send $RELAY_ADDRESS "setMaxTradeBps(uint256)" \
  2000 \
  --rpc-url $RPC_URL \
  --private-key $DAO_ADMIN_PRIVATE_KEY
```

### B) Update Max Slippage

```bash
# From DAO admin account
# Set to 10% (1000 basis points)
cast send $RELAY_ADDRESS "setMaxSlippageBps(uint256)" \
  1000 \
  --rpc-url $RPC_URL \
  --private-key $DAO_ADMIN_PRIVATE_KEY
```

### C) Update Trade Cooldown

```bash
# From DAO admin account
# Set to 2 minutes (120 seconds)
cast send $RELAY_ADDRESS "setTradeCooldownSec(uint256)" \
  120 \
  --rpc-url $RPC_URL \
  --private-key $DAO_ADMIN_PRIVATE_KEY
```

### D) View Current Risk Parameters

```bash
cast call $RELAY_ADDRESS "getRiskParameters()(uint256,uint256,uint256,uint256)" \
  --rpc-url $RPC_URL
```

Returns: `(maxTradeBps, maxSlippageBps, tradeCooldownSec, lastTradeTimestamp)`

## 7) Manage Traders (DAO Only)

### A) Authorize New Trader

```bash
# From DAO admin account
cast send $RELAY_ADDRESS "authorizeTrader(address)" \
  $NEW_TRADER_ADDRESS \
  --rpc-url $RPC_URL \
  --private-key $DAO_ADMIN_PRIVATE_KEY
```

### B) Revoke Trader Authorization

```bash
# From DAO admin account
cast send $RELAY_ADDRESS "revokeTrader(address)" \
  $TRADER_ADDRESS \
  --rpc-url $RPC_URL \
  --private-key $DAO_ADMIN_PRIVATE_KEY
```

### C) Check Trader Authorization

```bash
cast call $RELAY_ADDRESS "hasRole(bytes32,address)(bool)" \
  $(cast keccak "TRADER_ROLE") \
  $TRADER_ADDRESS \
  --rpc-url $RPC_URL
```

## 8) Monitor Cooldown Status

### Check Remaining Cooldown Time

```bash
cast call $RELAY_ADDRESS "getCooldownRemaining()(uint256)" \
  --rpc-url $RPC_URL
```

Returns seconds until next trade is allowed (0 if ready).

## 9) Event Monitoring

The Relay emits comprehensive events for transparency:

### Trade Lifecycle Events

- **TradeProposed**: Emitted when a trader submits a trade
- **TradeApproved**: Emitted when all validations pass
- **TradeForwarded**: Emitted when trade is sent to Treasury
- **TradeRejected**: Emitted on validation failure (with reason)

### Parameter Update Events

- **MaxTradeBpsUpdated**
- **MaxSlippageBpsUpdated**
- **TradeCooldownSecUpdated**

### Authorization Events

- **TraderAuthorized**
- **TraderRevoked**

### Query Events Example

```bash
# Get recent TradeProposed events
cast logs --from-block 1000000 \
  --address $RELAY_ADDRESS \
  --event "TradeProposed(address,uint8,address,address,uint256,uint256,uint256)" \
  --rpc-url $RPC_URL
```

## 10) Common Error Scenarios

### PairNotWhitelisted
```
Error: PairNotWhitelisted(tokenIn, tokenOut)
```
**Solution**: Whitelist the pair via PairWhitelist contract

### ExceedsMaxTradeSize
```
Error: ExceedsMaxTradeSize(requested, maxAllowed, maxTradeBps)
```
**Solution**: Reduce trade size or increase maxTradeBps via DAO

### ExceedsMaxSlippage
```
Error: ExceedsMaxSlippage(implied, maxAllowed)
```
**Solution**: Increase minAmountOut or adjust maxSlippageBps via DAO

### CooldownNotElapsed
```
Error: CooldownNotElapsed(remaining, required)
```
**Solution**: Wait for cooldown period to complete

### InsufficientTreasuryBalance
```
Error: InsufficientTreasuryBalance(available, requested)
```
**Solution**: Deposit more tokens to Treasury or reduce trade size

### Unauthorized Trader
```
Error: AccessControl: account is missing role
```
**Solution**: Authorize trader via `authorizeTrader()`

## 11) Testing Workflow

### Complete End-to-End Test

1. Deploy PairWhitelist, Relay, and update Treasury
2. Whitelist USDC -> HTK pair
3. Deposit USDC to Treasury
4. Authorize trader
5. Propose buyback-and-burn trade
6. Verify HTK burned
7. Check events on HashScan

### Test Rejection Scenarios

1. Try trade without whitelisting pair → Expect revert
2. Try trade exceeding max size → Expect revert
3. Try trade with excessive slippage → Expect revert
4. Execute trade, immediately try another → Expect cooldown revert
5. Try trade from unauthorized account → Expect revert
