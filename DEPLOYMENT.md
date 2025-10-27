# Deployment Guide

This guide explains how to deploy the ENSValidator and MockENS contracts.

## Prerequisites

1. Set up your environment variables in `.env`:
   ```bash
   PK=<your_private_key>
   MAINNET_RPC_URL=<your_rpc_url>
   MOCK_TOKEN=<optional_token_address_for_mock_ens>
   ```

## Deployment Scripts

### 1. Basic Deployment (`DeployENS.s.sol`)

Deploys ENSValidator and optionally MockENS without registry.

**Usage:**
```bash
# Deploy ENSValidator only
forge script script/DeployENS.s.sol --rpc-url <RPC_URL> --broadcast

# Deploy with MockENS (requires MOCK_TOKEN)
MOCK_TOKEN=0x... forge script script/DeployENS.s.sol --rpc-url <RPC_URL> --broadcast
```

### 2. Registry Deployment (`DeployENSWithRegistry.s.sol`)

Deploys ENSValidator through the module registry and optionally MockENS.

**Usage:**
```bash
# Deploy ENSValidator through registry
forge script script/DeployENSWithRegistry.s.sol --rpc-url <RPC_URL> --broadcast

# Deploy with MockENS and custom metadata
MOCK_TOKEN=0x... METADATA=0x... forge script script/DeployENSWithRegistry.s.sol --rpc-url <RPC_URL> --broadcast
```

**Optional Environment Variables:**
- `MOCK_TOKEN`: ERC20 token address for MockENS (if deploying MockENS)
- `RESOLVER_CONTEXT`: Custom resolver context (default: empty)
- `METADATA`: Custom metadata for registry deployment (default: empty)
- `SALT`: Custom salt for deterministic deployment (default: bytes32(0))

## Deployment Examples

### Local Testing
```bash
# Start local node
anvil

# Deploy to local network
forge script script/DeployENS.s.sol --rpc-url http://localhost:8545 --broadcast
```

### Testnet Deployment
```bash
# Deploy to Sepolia
forge script script/DeployENS.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### Mainnet Deployment
```bash
# Deploy to mainnet (use with caution!)
forge script script/DeployENSWithRegistry.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

## Verification

After deployment, verify contracts on Etherscan:

```bash
forge verify-contract <CONTRACT_ADDRESS> \
  src/validator/ENSValidator.sol:ENSValidator \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --chain-id <CHAIN_ID>
```

For MockENS (requires constructor argument):
```bash
forge verify-contract <MOCK_ENS_ADDRESS> \
  src/mocks/MockENS.sol:MockENS \
  --constructor-args $(cast abi-encode "constructor(address)" <TOKEN_ADDRESS>) \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --chain-id <CHAIN_ID>
```

## Gas Optimization

For optimized deployments with `via-ir` enabled (as configured in `foundry.toml`):

```bash
forge script script/DeployENS.s.sol \
  --rpc-url <RPC_URL> \
  --broadcast \
  --optimize \
  --optimizer-runs 200
```

## Troubleshooting

### "PK not set" Error
Ensure your `.env` file contains the `PK` variable with your private key.

### Gas Estimation Failed
Try increasing the gas limit or checking RPC endpoint connectivity.

### Deployment Address Collision
Use a different `SALT` value for deterministic deployments.
