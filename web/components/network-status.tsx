'use client'

import { useAccount, useChainId } from 'wagmi'
import { config, getL1Chain, getL2Chain } from '@/lib/config'

export function NetworkStatus() {
  const { isConnected } = useAccount()
  const chainId = useChainId()
  
  if (!isConnected) return null
  
  const isL1 = chainId === config.l1ChainId
  const isL2 = chainId === config.l2ChainId
  const isCorrectNetwork = isL1 || isL2
  
  return (
    <div className="flex items-center gap-2 text-sm">
      <div className={`h-2 w-2 rounded-full ${isCorrectNetwork ? 'bg-green-500' : 'bg-orange-500'}`} />
      <span className="text-gray-600">
        {isL1 && `Connected to ${getL1Chain().name}`}
        {isL2 && `Connected to ${getL2Chain().name}`}
        {!isCorrectNetwork && 'Wrong network'}
      </span>
    </div>
  )
}