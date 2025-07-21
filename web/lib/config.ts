import { createPublicClient, http } from 'viem'
import { mainnet, sepolia } from 'viem/chains'
import type { Address } from 'viem'
import { facetSepolia, facetMainnet } from './chains'

export const config = {
  l1ChainId: Number(process.env.NEXT_PUBLIC_L1_CHAIN_ID || 11155111),
  l2ChainId: Number(process.env.NEXT_PUBLIC_L2_CHAIN_ID || 16436858),
  
  l1RpcUrl: process.env.NEXT_PUBLIC_L1_RPC_URL || 'https://eth-sepolia.g.alchemy.com/v2/demo',
  l2RpcUrl: process.env.NEXT_PUBLIC_L2_RPC_URL || 'https://sepolia.facet.org',
  
  rollupAddress: (process.env.NEXT_PUBLIC_ROLLUP_ADDRESS || '0x0002fcfc87d560dfff2e20c9eadb17f59b2c3dc9') as Address,
  l1ETHBridgeAddress: (process.env.NEXT_PUBLIC_L1_ETH_BRIDGE_ADDRESS || '0x59bef954265a3957e736699de754ef3f2f3194ac') as Address,
  l2ETHBridgeAddress: (process.env.NEXT_PUBLIC_L2_ETH_BRIDGE_ADDRESS || '0x8484Fa5EE3a7d1Fd588D970fA655B10043962c45') as Address,
  
  withdrawalDelaySecs: Number(process.env.NEXT_PUBLIC_WITHDRAWAL_DELAY_SECS || 60),
  
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