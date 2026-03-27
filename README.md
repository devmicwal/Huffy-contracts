# Huffy Contracts

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Smart contract suite for the Huffy DAO treasury management system on Hedera. This repository contains the core contracts for managing treasury funds, executing validated trades, and implementing buyback-and-burn mechanisms.

## 📖 Table of Contents

- [Overview](#overview)
- [Core Architecture](#core-architecture)
- [Quick Start](#quick-start)
- [Documentation](#documentation)
- [Support & Resources](#support--resources)
- [License](#license)

## 🎯 Overview

The Huffy Contracts system implements a secure, DAO-controlled treasury with multi-layered validation for all trading operations. The architecture separates concerns between fund custody, trade validation, and pair management.

### Key Features

- 🏦 **DAO-Controlled Treasury** - Secure fund management with role-based access control    
- 🛡️ **Trade Validation Layer** - Multi-parameter risk checks before execution  
- 📜 **Pair Whitelisting** - Only approved trading pairs can be executed    
- ⚖️ **Position Size Limits** - Configurable maximum trade size as % of balance     
- 🔒 **Slippage Protection** - Enforced maximum slippage tolerance  
- ⏱️ **Rate Limiting** - Cooldown periods between trades    
- 🔥 **Buyback & Burn** - Automated Kairos token buyback and burning   
- 📊 **Comprehensive Events** - Full transparency via detailed event logs

## 🏗️ Core Architecture

The system is composed of five main contracts:

1. **[Treasury.sol](src/Treasury.sol)**
   Main contract holding DAO funds. Only accepts execution commands from the authorized Relay contract. Handles token deposits, generic swaps, and buyback-and-burn operations for the governance token.

2. **[Relay.sol](src/Relay.sol)**
   Validation gateway enforcing DAO risk parameters (trade size limits, slippage protection, rate limiting, and trader authorization) before forwarding trades to the Treasury.

3. **[PairWhitelist.sol](src/PairWhitelist.sol)**
   DAO-managed registry of approved trading pairs ensuring trades are only executed on verified token pairs.

4. **[ParameterStore.sol](src/ParameterStore.sol)**
   Manages and stores protocol-wide configuration parameters and settings.

5. **[SaucerswapAdapter.sol](src/SaucerswapAdapter.sol)**
   Integrates with the SaucerSwap DEX to execute required token swaps on Hedera.

## 🚀 Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/blockydevs/kairos-contracts
cd kairos-contracts

# Install dependencies
forge install
forge install OpenZeppelin/openzeppelin-contracts

# Build contracts
forge build
```

### Environment Setup

Create a `.env` file in the project root from `env.example` and fill in the required variables.

### Testing

#### Local Unit Testing
Run the Foundry suite of fast local tests:

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test contract
forge test --match-contract TreasuryTest
forge test --match-contract RelayTest

# Run with gas reporting
forge test --gas-report
```

#### Test Coverage

```bash
forge coverage
```

### Deployment

*Note: The execution order of the following steps is important.*

#### 1. Create DAO and Kairos Token
Action: Create DAO and Kairos Token via https://hashiodao.hashgraph.com
You will receive: `daoId`, `tokenId`, `timelockAddress`
*(How to find the timelock address: hashscan -> daoId -> create transaction -> parent transaction -> trace -> 1_1_7 -> 'to' address is timelock)*

#### 2. Deploy sc: PairWhitelist
Required environment variables:
- `TIMELOCK_ADDRESS`

```bash
forge script script/PairWhitelist.s.sol:DeployPairWhitelist --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
```

#### 3. Deploy sc: ParameterStore
Required environment variables:
- `TIMELOCK_ADDRESS`

```bash
forge script script/ParameterStore.s.sol:ParameterStoreDeploy --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
```

#### 4. Deploy sc: SwapRouterProxyV1
Required environment variables:
- `SAUCERSWAP_V1_ROUTER_ADDRESS="0x00000000000000000000000000000000002e7a5d"` (mainnet)
- `WHBAR_TOKEN_ADDRESS="0x0000000000000000000000000000000000163b5a"` (mainnet)

```bash
forge script script/SwapRouterProxyV1.s.sol:DeploySwapRouterProxyV1 --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
```

#### 5. Deploy sc: SwapRouterProxyV2
Required environment variables:
- `SAUCERSWAP_V2_ROUTER_ADDRESS="0x00000000000000000000000000000000003c437A"` (mainnet)
- `WHBAR_TOKEN_ADDRESS="0x0000000000000000000000000000000000163b5a"` (mainnet)

```bash
forge script script/SwapRouterProxyV2.s.sol:DeploySwapRouterProxyHedera --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
```

#### 6. Deploy sc: SaucerswapAdapter
Required environment variables from the previous steps:
- `SWAP_ROUTER_PROXY_V1_ADDRESS`
- `SWAP_ROUTER_PROXY_V2_ADDRESS`

```bash
forge script script/SaucerswapAdapter.s.sol:DeploySaucerswapAdapter --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
```

#### 7. Deploy sc: Treasury
Required environment variables:
- `HTK_TOKEN_ADDRESS` (kairos token address)
- `QUOTE_TOKEN_ADDRESS="0x000000000000000000000000000000000006f89a"` (mainnet)
- `SWAP_ADAPTER_ADDRESS`="..."
- `DAO_ADMIN_ADDRESS`="..."
- `RELAY_ADDRESS`="..." (any address as it will be updated in the next step)
- `BURN_SINK_ADDRESS`="..."
- `WHBAR_TOKEN_ADDRESS`="..."

```bash
forge script script/Treasury.s.sol:DeployTreasury --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
```

#### 8. Deploy sc: Relay
Required environment variables:
- `PAIR_WHITELIST_ADDRESS`="..."
- `PARAMETER_STORE_ADDRESS`="..."
- `TREASURY_ADDRESS`="..."
- `WHBAR_TOKEN_ADDRESS`="..."
- `DAO_ADMIN_ADDRESS`="..."
- `TIMELOCK_ADDRESS`="..."
- `INITIAL_TRADERS`="..."

```bash
forge script script/Relay.s.sol:DeployRelay --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv

cast send $TREASURY_ADDRESS "updateRelay(address,address)" $OLD_RELAY_ADDRESS $NEW_RELAY_ADDRESS --rpc-url $RPC_URL --private-key $PRIVATE_KEY
```

## 🤝 Support & Resources

- **Hedera Docs**: [https://docs.hedera.com/](https://docs.hedera.com/)
- **Saucerswap Docs**: [https://docs.saucerswap.finance/](https://docs.saucerswap.finance/)
- **Foundry Book**: [https://book.getfoundry.sh/](https://book.getfoundry.sh/)
- **HashScan Explorer**: [https://hashscan.io/](https://hashscan.io/)

## 📄 License

This project is licensed under the MIT License.
