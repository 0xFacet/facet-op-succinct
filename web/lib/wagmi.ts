import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { sepolia } from 'wagmi/chains'
import { facetSepolia } from './chains'
import { config } from './config'

export const wagmiConfig = getDefaultConfig({
  appName: 'Facet Bridge',
  projectId: config.walletConnectProjectId || 'YOUR_PROJECT_ID',
  chains: [sepolia, facetSepolia],
  ssr: true,
})