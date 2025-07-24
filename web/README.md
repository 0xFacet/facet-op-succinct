# OP Succinct Web & Scripts

This directory contains both the web application and CLI scripts for withdrawing funds from OP Succinct L2 to L1 using ZK proofs.

## Features

- 🔐 Connect wallet with RainbowKit
- 🔄 Step-by-step withdrawal wizard
- ⚡ Real-time proposal monitoring
- 💾 Progress persistence
- 📱 Mobile responsive
- 🚀 Built with latest tech: Next.js 15, Tailwind v4, wagmi v2

## Quick Start

### Development

1. Copy environment variables:
   ```bash
   cp .env.example .env.local
   ```

2. Install dependencies:
   ```bash
   pnpm install
   ```

3. Run development server:
   ```bash
   pnpm dev
   ```

4. Open [http://localhost:3000](http://localhost:3000)

### Production Build

```bash
pnpm build
pnpm start
```

## Environment Variables

Create a `.env.local` file with:

```env
# RPC URLs
NEXT_PUBLIC_L1_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
NEXT_PUBLIC_L2_RPC_URL=https://sepolia.optimism.io

# Contract Addresses
NEXT_PUBLIC_ROLLUP_ADDRESS=0xb3e0406017407baEd43652C440b304B858432B98
NEXT_PUBLIC_L1_BRIDGE_ADDRESS=0x4A7Db6a4ACe349d69BB72E73ABe2712a76E15428

# Chain IDs
NEXT_PUBLIC_L1_CHAIN_ID=11155111  # Sepolia
NEXT_PUBLIC_L2_CHAIN_ID=11155420  # OP Sepolia

# Optional
NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID=your_project_id
NEXT_PUBLIC_WITHDRAWAL_DELAY_SECS=60
```

## Deployment

### Deploy to Vercel

1. Push to GitHub
2. Import project in Vercel
3. Set environment variables in Vercel dashboard
4. Deploy!

The app is configured for Vercel with:
- Root directory: `/web`
- Build command: `pnpm build`
- Node.js 22.x

### Manual Deployment

```bash
# Build
pnpm build

# Preview
pnpm start
```

## Withdrawal Process

1. **Connect Wallet** - Connect with MetaMask or WalletConnect
2. **Enter TX Hash** - Provide your L2 withdrawal transaction hash
3. **Wait for Proposal** - Monitor for canonical proposal (auto-refresh)
4. **Prove Withdrawal** - Submit proof on L1
5. **Finalize** - Complete withdrawal after delay

## Tech Stack

- **Next.js 15.4** - React framework with App Router
- **React 19.1** - Latest React
- **TypeScript 5.8** - Type safety
- **Tailwind CSS v4** - Styling with 5x faster builds
- **wagmi v2.15** - Ethereum React hooks
- **viem v2.32** - TypeScript Ethereum library
- **RainbowKit v2.2** - Wallet connection UI

## Project Structure

```
web/
├── app/              # Next.js App Router
├── components/       # React components
│   └── withdrawal-wizard/  # Multi-step wizard
├── lib/              # Utilities and configs
│   ├── actions/      # Viem actions for OP-Succinct
│   ├── config.ts     # Configuration
│   └── contracts.ts  # Contract ABIs
├── scripts/          # CLI scripts for testing
│   ├── prove-from-tx.ts              # Simple withdrawal from tx hash
│   ├── prove-and-withdraw.ts         # Full withdrawal example
│   ├── prove-and-finalize-sepolia.ts # Sepolia-specific example
│   └── complete-withdrawal-flow.ts   # Complete flow demonstration
├── public/           # Static assets
└── vercel.json       # Vercel config
```

## CLI Scripts

The `scripts/` directory contains command-line tools for testing withdrawals:

### prove-from-tx
Simplest script - just provide a withdrawal transaction hash:
```bash
pnpm prove-from-tx 0x123...
```

### prove-and-withdraw
Complete example showing the full withdrawal flow:
```bash
pnpm prove-withdraw
```

### Environment Setup
The scripts will automatically load from `../contracts/.env.sepolia` if it exists.

## Development Notes

- All viem actions are in `lib/actions/` and shared between web app and scripts
- Withdrawal progress is saved in localStorage
- Supports Sepolia testnet by default
- Can be configured for mainnet by updating environment variables

## Troubleshooting

**Wrong Network Error**
- Click network switch button in the UI
- Wizard automatically prompts for correct network

**Transaction Fails**
- Ensure you have enough ETH for gas
- Check contract addresses in `.env.local`
- Verify you're on the correct network

**Proposal Not Found**
- Proposals are submitted periodically (~5-10 mins)
- The page auto-refreshes every 30 seconds
- Check that your withdrawal tx was successful on L2

## License

MIT