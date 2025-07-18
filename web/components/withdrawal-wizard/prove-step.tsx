'use client'

import { useState } from 'react'
import { formatEther } from 'viem'
import { useWalletClient, useChainId, useSwitchChain } from 'wagmi'
import { l1PublicClient, l2PublicClient, config } from '@/lib/config'
import { L1_ETH_BRIDGE_ABI, ROLLUP_ABI } from '@/lib/contracts'
import type { WithdrawalData } from '@/lib/withdrawal-actions'
import { buildProveWithdrawalSuccinct, proveWithdrawalSuccinct } from '@/lib/actions'
import { useLatestWithdrawal } from '@/hooks/useLatestWithdrawal'

interface ProveStepProps {
  withdrawalData: WithdrawalData
  proposalId: number
  onProven: (provenAt: number) => void
}

export function ProveStep({ withdrawalData, proposalId, onProven }: ProveStepProps) {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  
  const chainId = useChainId()
  const { switchChain } = useSwitchChain()
  const { data: walletClient } = useWalletClient()
  const isOnL1 = chainId === config.l1ChainId
  
  // Get the withdrawal block number
  const { withdrawal } = useLatestWithdrawal()

  const handleProve = async () => {
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
      if (!withdrawal) {
        throw new Error('Could not find withdrawal block number')
      }

      // Get proposal data
      const proposal = await l1PublicClient.readContract({
        address: config.rollupAddress,
        abi: ROLLUP_ABI,
        functionName: 'getProposal',
        args: [BigInt(proposalId)]
      })

      console.log('Building withdrawal proof...')
      console.log('Proposal:', proposal)
      console.log('Withdrawal block:', withdrawal.blockNumber)

      // Build the proof parameters using the same logic as the script
      const proofParams = await buildProveWithdrawalSuccinct(l1PublicClient, {
        to: withdrawalData.to,
        amount: withdrawalData.amount,
        nonce: withdrawalData.nonce,
        proposalId: BigInt(proposalId),
        outputRoot: proposal.rootClaim,
        l2BlockNumber: BigInt(proposal.l2BlockNumber), // Use the proposal's block number
        bridgeAddress: config.l1ETHBridgeAddress,
        l2Client: l2PublicClient
      })

      console.log('Proof params built, submitting transaction...')

      // Submit prove transaction using the built parameters
      const tx = await proveWithdrawalSuccinct(walletClient as any, proofParams)

      // Wait for confirmation
      const receipt = await l1PublicClient.waitForTransactionReceipt({ hash: tx })
      
      if (receipt.status === 'success') {
        const timestamp = Math.floor(Date.now() / 1000)
        onProven(timestamp)
      } else {
        throw new Error('Transaction failed')
      }
    } catch (err) {
      console.error('Prove error:', err)
      setError(err instanceof Error ? err.message : 'Failed to prove withdrawal')
    } finally {
      setLoading(false)
    }
  }

  return (
    <div>
      <h3 className="text-lg font-semibold mb-4">Step 3: Prove Withdrawal</h3>
      
      {!isOnL1 && (
        <div className="mb-4 p-4 bg-orange-50 border border-orange-200 rounded-lg">
          <p className="text-sm text-orange-800">
            You need to be on L1 to prove the withdrawal. 
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
        <div className="p-4 bg-green-50 border border-green-200 rounded-lg">
          <p className="text-sm text-green-800 mb-1">
            Your withdrawal is ready to be proven!
          </p>
          <p className="text-xs text-green-600">
            Proposal #{proposalId} is canonical and contains your withdrawal.
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

        {error && (
          <div className="p-3 bg-red-50 border border-red-200 rounded-lg">
            <p className="text-sm text-red-600">{error}</p>
          </div>
        )}

        <button
          onClick={handleProve}
          disabled={loading || !isOnL1}
          className="w-full py-2 px-4 bg-blue-500 text-white rounded-lg hover:bg-blue-600 disabled:bg-gray-300 disabled:cursor-not-allowed transition-colors"
        >
          {loading ? 'Proving...' : 'Prove Withdrawal'}
        </button>

        <div className="p-3 bg-gray-50 rounded-lg">
          <p className="text-xs text-gray-600">
            <strong>Note:</strong> This will submit a proof that your withdrawal exists in the 
            L2 state. After proving, you'll need to wait for a short delay before finalizing.
          </p>
        </div>
      </div>
    </div>
  )
}