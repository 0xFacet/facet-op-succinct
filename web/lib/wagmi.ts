import { getDefaultConfig } from '@rainbow-me/rainbowkit'
import { config, getL1Chain } from './config'

// Dynamically determine which L1 chain to include based on config
const l1Chain = getL1Chain()
const chains = [l1Chain] as const

export const wagmiConfig = getDefaultConfig({
  appName: 'Facet ZK Fault Proofs',
  projectId: config.walletConnectProjectId || 'YOUR_PROJECT_ID',
  chains,
  ssr: true,
})
