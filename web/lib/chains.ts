import { defineChain } from 'viem'

export const facetSepolia = defineChain({
  id: 16436858,
  name: 'Facet Sepolia',
  nativeCurrency: {
    decimals: 18,
    name: 'Ether',
    symbol: 'ETH',
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