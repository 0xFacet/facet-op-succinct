'use client'

import { useEffect, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { l1PublicClient, config } from '@/lib/config'
import { ROLLUP_ABI } from '@/lib/contracts'
import type { Proposal } from '@/lib/actions/types'

interface ProposalWithTimestamp extends Proposal {
  timestamp?: number
}

interface ProposalTrackingData {
  latestProposal: ProposalWithTimestamp | null
  proposalCount: number
  proposalsSinceTimestamp: ProposalWithTimestamp[]
  isLoading: boolean
}

export function useProposalTracking(sinceTimestamp?: number) {
  const [proposals, setProposals] = useState<ProposalWithTimestamp[]>([])

  // Get the current proposal count
  const { data: proposalCount = 0 } = useQuery({
    queryKey: ['proposalCount'],
    queryFn: async () => {
      const count = await l1PublicClient.readContract({
        address: config.rollupAddress,
        abi: ROLLUP_ABI,
        functionName: 'getProposalsLength'
      })
      return Number(count)
    },
    refetchInterval: 15000 // Check every 15 seconds
  })

  // Get all proposals since the given timestamp
  const { data: proposalData, isLoading } = useQuery({
    queryKey: ['proposals', proposalCount, sinceTimestamp],
    queryFn: async () => {
      if (proposalCount === 0) return []
      
      const allProposals: ProposalWithTimestamp[] = []
      
      // Start from the most recent and work backwards
      for (let i = proposalCount - 1; i >= 0; i--) {
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
        
        // Only include canonical proposals
        if (!isCanonical) continue
        
        const proposalData: ProposalWithTimestamp = {
          rootClaim: proposal.rootClaim,
          proposer: proposal.proposer,
          l2BlockNumber: proposal.l2BlockNumber,
          parentIndex: proposal.parentIndex,
          deadline: proposal.deadline,
          resolvedAt: proposal.resolvedAt,
          proposalStatus: proposal.proposalStatus,
          resolutionStatus: proposal.resolutionStatus,
          challenger: proposal.challenger,
          prover: proposal.prover,
          timestamp: proposal.deadline // deadline is the timestamp when it was created
        }
        
        allProposals.push(proposalData)
        
        // If we have a timestamp filter, stop when we reach proposals before that time
        if (sinceTimestamp && proposal.deadline < sinceTimestamp) {
          break
        }
        
        // Only get the last 10 proposals max to avoid too many RPC calls
        if (allProposals.length >= 10) break
      }
      
      return allProposals
    },
    enabled: proposalCount > 0,
    refetchInterval: 15000 // Check every 15 seconds
  })

  useEffect(() => {
    if (proposalData) {
      console.log('[useProposalTracking] Found proposals:', proposalData.length)
      if (proposalData.length > 0) {
        console.log('[useProposalTracking] Latest proposal:', {
          l2BlockNumber: proposalData[0].l2BlockNumber,
          timestamp: proposalData[0].timestamp,
          minutesAgo: proposalData[0].timestamp ? Math.floor((Date.now() / 1000 - proposalData[0].timestamp) / 60) : 'unknown'
        })
      }
      setProposals(proposalData)
    }
  }, [proposalData])

  const latestProposal = proposals.length > 0 ? proposals[0] : null
  const proposalsSinceTimestamp = sinceTimestamp 
    ? proposals.filter(p => p.deadline >= sinceTimestamp)
    : proposals

  return {
    latestProposal,
    proposalCount,
    proposalsSinceTimestamp,
    isLoading
  }
}