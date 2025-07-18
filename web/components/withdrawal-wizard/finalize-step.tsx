'use client'

import { useState, useEffect } from 'react'
import { formatEther } from 'viem'
import { useWalletClient, useChainId, useSwitchChain } from 'wagmi'
import { l1PublicClient, config } from '@/lib/config'
import { L1_ETH_BRIDGE_ABI } from '@/lib/contracts'
import type { WithdrawalData } from '@/lib/withdrawal-actions'

interface FinalizeStepProps {
  withdrawalData: WithdrawalData
  provenAt: number
  onFinalized: () => void
}

export function FinalizeStep({ withdrawalData, provenAt, onFinalized }: FinalizeStepProps) {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [canFinalize, setCanFinalize] = useState(false)
  const [timeRemaining, setTimeRemaining] = useState(0)
  const [isFinalized, setIsFinalized] = useState(false)
  
  const chainId = useChainId()
  const { switchChain } = useSwitchChain()
  const { data: walletClient } = useWalletClient()
  const isOnL1 = chainId === config.l1ChainId

  // Check if withdrawal can be finalized
  useEffect(() => {
    const checkFinalizability = () => {
      const now = Math.floor(Date.now() / 1000)
      const readyAt = provenAt + config.withdrawalDelaySecs
      const remaining = readyAt - now
      
      setCanFinalize(remaining <= 0)
      setTimeRemaining(Math.max(0, remaining))
    }

    checkFinalizability()
    const interval = setInterval(checkFinalizability, 1000)
    return () => clearInterval(interval)
  }, [provenAt])

  const handleFinalize = async () => {
    if (!walletClient) {
      setError('Please connect your wallet')
      return
    }

    if (!isOnL1) {
      await switchChain({ chainId: config.l1ChainId })
      return
    }

    setLoading(true)
    setError(null)

    try {
      // Submit finalize transaction
      const tx = await walletClient.writeContract({
        address: config.l1ETHBridgeAddress,
        abi: L1_ETH_BRIDGE_ABI,
        functionName: 'finaliseWithdrawal',
        args: [
          withdrawalData.to,
          withdrawalData.amount,
          withdrawalData.nonce
        ],
        chain: walletClient.chain,
      })

      // Wait for confirmation
      const receipt = await l1PublicClient.waitForTransactionReceipt({ hash: tx })
      
      if (receipt.status === 'success') {
        setIsFinalized(true)
        // Don't call onFinalized immediately, let user clear manually
      } else {
        throw new Error('Transaction failed')
      }
    } catch (err) {
      console.error('Finalize error:', err)
      setError(err instanceof Error ? err.message : 'Failed to finalize withdrawal')
    } finally {
      setLoading(false)
    }
  }

  const formatTime = (seconds: number) => {
    const mins = Math.floor(seconds / 60)
    const secs = seconds % 60
    return `${mins}:${secs.toString().padStart(2, '0')}`
  }

  return (
    <div>
      {isFinalized ? (
        <>
          <h3 className="text-lg font-semibold mb-4 text-green-600">✅ Withdrawal Complete!</h3>
          
          <div className="space-y-4">
            <div className="p-4 bg-green-50 border border-green-200 rounded-lg">
              <p className="text-sm text-green-800 mb-2">
                Your withdrawal has been successfully finalized!
              </p>
              <p className="text-xs text-green-600">
                The funds have been transferred to your L1 address.
              </p>
            </div>
            
            <div className="space-y-2">
              <div className="flex justify-between text-sm">
                <span className="text-gray-600">Amount:</span>
                <span>{formatEther(withdrawalData.amount)} ETH</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-gray-600">Recipient:</span>
                <span className="font-mono text-xs">{withdrawalData.to}</span>
              </div>
            </div>
            
            <button
              onClick={() => {
                onFinalized()
                window.location.reload()
              }}
              className="w-full py-2 px-4 bg-blue-500 text-white rounded-lg hover:bg-blue-600 transition-colors"
            >
              Start New Withdrawal
            </button>
          </div>
        </>
      ) : (
        <>
          <h3 className="text-lg font-semibold mb-4">Step 4: Finalize Withdrawal</h3>
          
          {!isOnL1 && (
            <div className="mb-4 p-4 bg-orange-50 border border-orange-200 rounded-lg">
              <p className="text-sm text-orange-800">
                You need to be on L1 to finalize the withdrawal. 
                <button
                  onClick={() => switchChain({ chainId: config.l1ChainId })}
                  className="ml-2 text-orange-600 underline hover:text-orange-700"
                >
                  Switch to L1
                </button>
              </p>
            </div>
          )}

          <div className="space-y-4">
            {!canFinalize ? (
              <div className="p-4 bg-yellow-50 border border-yellow-200 rounded-lg">
                <p className="text-sm text-yellow-800 mb-1">
                  Waiting for security delay...
                </p>
                <p className="text-2xl font-bold text-yellow-900">
                  {formatTime(timeRemaining)}
                </p>
                <p className="text-xs text-yellow-600 mt-1">
                  This delay ensures the security of the withdrawal process.
                </p>
              </div>
            ) : (
              <div className="p-4 bg-green-50 border border-green-200 rounded-lg">
                <p className="text-sm text-green-800">
                  Your withdrawal is ready to be finalized!
                </p>
              </div>
            )}

            <div className="space-y-2">
              <div className="flex justify-between text-sm">
                <span className="text-gray-600">Amount:</span>
                <span>{formatEther(withdrawalData.amount)} ETH</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-gray-600">Recipient:</span>
                <span className="font-mono text-xs">{withdrawalData.to}</span>
              </div>
            </div>

            {error && (
              <div className="p-3 bg-red-50 border border-red-200 rounded-lg">
                <p className="text-sm text-red-600">{error}</p>
              </div>
            )}

            <button
              onClick={handleFinalize}
              disabled={loading || !canFinalize || !isOnL1}
              className="w-full py-2 px-4 bg-blue-500 text-white rounded-lg hover:bg-blue-600 disabled:bg-gray-300 disabled:cursor-not-allowed transition-colors"
            >
              {loading ? 'Finalizing...' : 'Finalize Withdrawal'}
            </button>

            <div className="p-3 bg-gray-50 rounded-lg">
              <p className="text-xs text-gray-600">
                <strong>Final step!</strong> This will transfer the funds to your L1 address. 
                The transaction will complete the withdrawal process.
              </p>
            </div>
          </div>
        </>
      )}
    </div>
  )
}