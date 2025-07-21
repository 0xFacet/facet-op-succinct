import { defineChain } from 'viem'

export const facetSepolia = defineChain({
  id: 16436858,
  name: 'Facet Sepolia',
  nativeCurrency: {
    decimals: 18,
    name: 'Facet Compute Token',
    symbol: 'FCT',
  },
  rpcUrls: {
    default: {
      http: [process.env.NEXT_PUBLIC_L2_RPC_URL || 'https://sepolia.facet.org'],
    },
  },
  blockExplorers: {
    default: { name: 'Explorer', url: 'https://sepolia.explorer.facet.org' },
  },
  testnet: true,
})

export const facetMainnet = defineChain({
  id: 1027303,
  name: 'Facet Mainnet',
  nativeCurrency: {
    decimals: 18,
    name: 'Facet Compute Token',
    symbol: 'FCT',
  },
  rpcUrls: {
    default: {
      http: [process.env.NEXT_PUBLIC_L2_RPC_URL || 'https://mainnet.facet.org'],
    },
  },
  blockExplorers: {
    default: { name: 'Explorer', url: 'https://explorer.facet.org' },
  },
  testnet: false,
})
