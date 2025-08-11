import { createPublicClient, http } from 'viem'
import { mainnet, sepolia } from 'viem/chains'
import type { Address } from 'viem'
import { facetSepolia, facetMainnet } from './chains'

// Configuration from environment variables
// These MUST be set in Vercel or local .env file
export const config = {
  // Chain IDs
  l1ChainId: Number(process.env.NEXT_PUBLIC_L1_CHAIN_ID!),
  l2ChainId: Number(process.env.NEXT_PUBLIC_L2_CHAIN_ID!),
  
  // RPC URLs
  l1RpcUrl: process.env.NEXT_PUBLIC_L1_RPC_URL!,
  l2RpcUrl: process.env.NEXT_PUBLIC_L2_RPC_URL!,
  
  // Contract Addresses (from deployment script output)
  rollupAddress: process.env.NEXT_PUBLIC_ROLLUP_ADDRESS as Address,
  l1BridgeAddress: process.env.NEXT_PUBLIC_L1_BRIDGE_ADDRESS as Address,
  l2BridgeAddress: process.env.NEXT_PUBLIC_L2_BRIDGE_ADDRESS as Address,
  
  // Withdrawal delay in seconds
  withdrawalDelaySecs: Number(process.env.NEXT_PUBLIC_WITHDRAWAL_DELAY_SECS!),
  
  // Wallet Connect Project ID (optional)
  walletConnectProjectId: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || ''
}

// Chain configs
export const getL1Chain = () => {
  switch (config.l1ChainId) {
    case 1:
      return mainnet
    case 11155111:
      return sepolia
    default:
      throw new Error(`Unsupported L1 chain ID: ${config.l1ChainId}`)
  }
}

export const getL2Chain = () => {
  // Use mainnet Facet when L1 is mainnet, otherwise use Sepolia
  if (config.l1ChainId === 1) {
    return facetMainnet
  }
  return facetSepolia
}

// Create clients
export const l1PublicClient = createPublicClient({
  chain: getL1Chain(),
  transport: http(config.l1RpcUrl),
})

export const l2PublicClient = createPublicClient({
  chain: getL2Chain(),
  transport: http(config.l2RpcUrl),
})