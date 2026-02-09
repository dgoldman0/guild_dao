# Guild DAO - Development Setup

## Quick Start

### 1. Install Dependencies
```bash
npm install
```

### 2. Configure Environment
Copy `.env.example` to `.env` and fill in your values:
```bash
cp .env.example .env
```

Required environment variables:
- `PRIVATE_KEY`: Your wallet private key (without 0x prefix) for deployment
- `ARBISCAN_API_KEY`: API key from https://arbiscan.io/myapikey for contract verification

### 3. Compile Contracts
```bash
npm run compile
```

### 4. Run Tests
```bash
npm test
```

### 5. Deploy to Arbitrum Sepolia Testnet
```bash
npm run deploy:arbitrum-sepolia
```

## Network Information

### Arbitrum Sepolia (Testnet)
- Chain ID: 421614
- RPC URL: https://sepolia-rollup.arbitrum.io/rpc
- Block Explorer: https://sepolia.arbiscan.io
- Faucet: https://faucet.quicknode.com/arbitrum/sepolia

### Arbitrum One (Mainnet)
- Chain ID: 42161
- RPC URL: https://arb1.arbitrum.io/rpc
- Block Explorer: https://arbiscan.io

## Getting Test ETH

1. Get Sepolia ETH from https://sepoliafaucet.com/
2. Bridge Sepolia ETH to Arbitrum Sepolia using https://bridge.arbitrum.io/

Alternatively, use QuickNode's direct faucet: https://faucet.quicknode.com/arbitrum/sepolia

## Project Structure

```
.
├── RankedMembershipDAO.sol    # Main DAO contract
├── MembershipTreasury.sol     # Treasury contract
├── scripts/
│   └── deploy.js              # Deployment script
├── test/
│   └── Treasury.test.js       # Test suite
├── hardhat.config.js          # Hardhat configuration
└── package.json               # Dependencies
```

## Useful Commands

- `npm run compile` - Compile all contracts
- `npm test` - Run test suite
- `npm run deploy:arbitrum-sepolia` - Deploy to Arbitrum Sepolia testnet
- `npm run node` - Start local Hardhat node
- `npm run verify` - Verify contracts on Arbiscan

## Contract Verification

After deployment, contracts will be automatically verified on Arbiscan. If automatic verification fails, you can manually verify using:

```bash
npx hardhat verify --network arbitrumSepolia <CONTRACT_ADDRESS> <CONSTRUCTOR_ARGS>
```

## Troubleshooting

### "Insufficient funds" error
Make sure your deployment wallet has enough Arbitrum Sepolia ETH.

### RPC errors
If you experience RPC issues, you can use alternative providers:
- Alchemy: https://arb-sepolia.g.alchemy.com/v2/YOUR-API-KEY
- Infura: https://arbitrum-sepolia.infura.io/v3/YOUR-API-KEY

Update the `ARBITRUM_SEPOLIA_RPC_URL` in your `.env` file.

## Security Notes

- Never commit your `.env` file
- Keep your private keys secure
- Use a separate wallet for testnet deployments
- Always test on testnet before mainnet deployment
