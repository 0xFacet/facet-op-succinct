'use client'

import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { formatEther } from 'viem'
import { l1PublicClient, l2PublicClient, config } from '@/lib/config'
import { type WithdrawalData } from '@/lib/withdrawal-actions'
import { findCanonicalProposal, type OutputRootProof } from '@/lib/actions'
import { useProposalTracking } from '@/hooks/useProposalTracking'
import { useLatestWithdrawal } from '@/hooks/useLatestWithdrawal'
import { ROLLUP_ABI } from '@/lib/contracts'

interface WaitProposalStepProps {
  withdrawalData: WithdrawalData
  txHash?: string
  onProposalFound: (proposalId: number) => void
}

export function WaitProposalStep({ withdrawalData, txHash, onProposalFound }: WaitProposalStepProps) {
  const [outputRootProof, setOutputRootProof] = useState<OutputRootProof | null>(null)
  const [l2BlockNumber, setL2BlockNumber] = useState<bigint | null>(null)
  const [proposalInterval, setProposalInterval] = useState<number | null>(null)
  
  // Get the withdrawal details to know when it was created
  const { withdrawal } = useLatestWithdrawal()
  const withdrawalTimestamp = withdrawal ? Math.floor(Date.now() / 1000) - 3600 : undefined // Look back 1 hour
  
  // Track proposals since the withdrawal
  const { latestProposal, proposalsSinceTimestamp, proposalCount } = useProposalTracking(withdrawalTimestamp)
  
  // Get the proposal interval from the rollup contract
  useEffect(() => {
    async function fetchProposalInterval() {
      try {
        const interval = await l1PublicClient.readContract({
          address: config.rollupAddress,
          abi: ROLLUP_ABI,
          functionName: 'PROPOSAL_INTERVAL'
        })
        setProposalInterval(Number(interval))
      } catch (err) {
        console.error('Failed to fetch proposal interval:', err)
      }
    }
    fetchProposalInterval()
  }, [])

  // Get the L2 block that contains the withdrawal
  useEffect(() => {
    async function getL2BlockData() {
      if (!withdrawal) return
      
      // Use the actual block number from the withdrawal
      const blockNumber = withdrawal.blockNumber
      setL2BlockNumber(blockNumber)
      
      // Get the block data for output root proof
      const block = await l2PublicClient.getBlock({ blockNumber })
      const stateRoot = await l2PublicClient.getProof({
        address: '0x4200000000000000000000000000000000000016', // L2ToL1MessagePasser
        storageKeys: [],
        blockNumber: blockNumber
      }).then(proof => proof.storageHash)

      setOutputRootProof({
        version: '0x0000000000000000000000000000000000000000000000000000000000000000',
        stateRoot: stateRoot,
        messagePasserStorageRoot: stateRoot, // Simplified - would need actual storage root
        latestBlockhash: block.hash!
      })
    }

    getL2BlockData()
  }, [withdrawal])

  // Check if withdrawal is covered by a canonical proposal
  const { data: proposalId, isLoading } = useQuery({
    queryKey: ['findProposal', l2BlockNumber?.toString(), latestProposal?.l2BlockNumber],
    queryFn: async () => {
      if (!l2BlockNumber || !latestProposal) return null
      
      // Check if the latest canonical proposal covers our withdrawal block
      if (latestProposal.l2BlockNumber >= Number(l2BlockNumber)) {
        console.log('[WaitProposalStep] Withdrawal block', l2BlockNumber.toString(), 'is covered by proposal at block', latestProposal.l2BlockNumber)
        
        // Find the proposal ID for this block number
        const proposalCount = await l1PublicClient.readContract({
          address: config.rollupAddress,
          abi: ROLLUP_ABI,
          functionName: 'getProposalsLength'
        })
        
        // Search backwards for the canonical proposal with this block number
        for (let i = Number(proposalCount) - 1; i >= 0; i--) {
          const [proposal, isCanonical] = await Promise.all([
            l1PublicClient.readContract({
              address: config.rollupAddress,
              abi: ROLLUP_ABI,
              functionName: 'getProposal',
              args: [BigInt(i)]
            }),
            l1PublicClient.readContract({
              address: config.rollupAddress,
              abi: ROLLUP_ABI,
              functionName: 'proposalIsCanonical',
              args: [BigInt(i)]
            })
          ])
          
          if (isCanonical && proposal.l2BlockNumber === latestProposal.l2BlockNumber) {
            return i
          }
        }
      }
      
      console.log('[WaitProposalStep] No proposal covers withdrawal block', l2BlockNumber.toString(), 'yet')
      return null
    },
    enabled: !!l2BlockNumber && !!latestProposal,
    refetchInterval: 30000, // Check every 30 seconds
  })

  useEffect(() => {
    if (proposalId !== null && proposalId !== undefined) {
      console.log('[WaitProposalStep] Found proposal:', proposalId)
      onProposalFound(Number(proposalId))
    }
  }, [proposalId, onProposalFound])

  return (
    <div>
      <h3 className="text-lg font-semibold mb-4">Step 2: Waiting for Proposal</h3>
      
      <div className="space-y-4">
        <div className="p-4 bg-blue-50 border border-blue-200 rounded-lg">
          <p className="text-sm text-blue-800 mb-2">
            Waiting for your withdrawal to be included in a canonical proposal...
          </p>
          <p className="text-xs text-blue-600">
            This typically takes 5-10 minutes. The page will update automatically.
          </p>
          {latestProposal && (
            <div className="mt-3 pt-3 border-t border-blue-200">
              <p className="text-xs text-blue-700 font-medium">Latest Proposal:</p>
              <p className="text-xs text-blue-600">
                L2 Block #{latestProposal.l2BlockNumber} 
                {proposalsSinceTimestamp.length > 0 && (
                  <span className="ml-2">({proposalsSinceTimestamp.length} proposals since your withdrawal)</span>
                )}
              </p>
            </div>
          )}
        </div>

        <div className="space-y-2">
          <div className="flex justify-between text-sm">
            <span className="text-gray-600">Recipient:</span>
            <span className="font-mono">{withdrawalData.to}</span>
          </div>
          <div className="flex justify-between text-sm">
            <span className="text-gray-600">Amount:</span>
            <span>{formatEther(withdrawalData.amount)} ETH</span>
          </div>
          <div className="flex justify-between text-sm">
            <span className="text-gray-600">Nonce:</span>
            <span className="font-mono text-xs">{withdrawalData.nonce.toString()}</span>
          </div>
          {l2BlockNumber && (
            <div className="flex justify-between text-sm">
              <span className="text-gray-600">L2 Block:</span>
              <span>{l2BlockNumber.toString()}</span>
            </div>
          )}
          {txHash && (
            <div className="flex justify-between text-sm">
              <span className="text-gray-600">Transaction:</span>
              <a 
                href={`https://sepolia.explorer.facet.org/tx/${txHash}`}
                target="_blank"
                rel="noopener noreferrer"
                className="text-blue-600 hover:text-blue-700 underline text-xs"
              >
                View on Explorer ↗
              </a>
            </div>
          )}
        </div>
        
        {/* Latest Proposal Info */}
        <div className="mt-4 p-3 bg-gray-50 rounded-lg">
          <h4 className="text-sm font-medium text-gray-700 mb-2">Latest Proposal Status</h4>
          {latestProposal ? (
            <div className="space-y-1 text-xs text-gray-600">
              <p>
                Last proposal: L2 Block #{latestProposal.l2BlockNumber}
              </p>
              {latestProposal.timestamp && (
                <p className="text-gray-500">
                  Posted {Math.floor((Date.now() / 1000 - latestProposal.timestamp) / 60)} minutes ago
                </p>
              )}
              {withdrawal && l2BlockNumber && (
                <>
                  <p>
                    Your withdrawal is at block #{l2BlockNumber.toString()} 
                    {Number(l2BlockNumber) > latestProposal.l2BlockNumber && (
                      <span className="text-orange-600 ml-1">
                        (waiting for next proposal)
                      </span>
                    )}
                  </p>
                  {proposalInterval && Number(l2BlockNumber) > latestProposal.l2BlockNumber && (
                    <p className="text-orange-600">
                      Estimated time until proposal: {(() => {
                        const blocksUntilNext = proposalInterval - ((Number(l2BlockNumber) - latestProposal.l2BlockNumber) % proposalInterval)
                        const blocksNeeded = blocksUntilNext + proposalInterval // Add extra interval for finalization
                        const secondsPerBlock = 12 // L1 and L2 block time
                        const minutesRemaining = Math.ceil((blocksNeeded * secondsPerBlock) / 60)
                        return `~${minutesRemaining} minutes`
                      })()}
                    </p>
                  )}
                </>
              )}
              <p className="text-gray-500 mt-2">
                Proposals are submitted periodically by the rollup proposer. 
                {proposalsSinceTimestamp.length > 0 && (
                  <span> ({proposalsSinceTimestamp.length} proposals in the last hour)</span>
                )}
              </p>
            </div>
          ) : (
            <p className="text-xs text-gray-500">
              {proposalCount === 0 ? 'Loading proposal data...' : 'No canonical proposals found yet'}
            </p>
          )}
        </div>

        {isLoading && (
          <div className="flex items-center justify-center py-8">
            <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-500"></div>
          </div>
        )}

        <div className="p-3 bg-gray-50 rounded-lg">
          <p className="text-xs text-gray-600">
            <strong>What's happening?</strong> The OP Succinct proposer periodically submits 
            proposals containing L2 state roots to L1. Once your withdrawal is included in a 
            canonical (accepted) proposal, you can prove and finalize it.
          </p>
        </div>
      </div>
    </div>
  )
}