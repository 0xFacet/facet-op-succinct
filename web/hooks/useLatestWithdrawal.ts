'use client'

import { useEffect, useState } from 'react'
import { useAccount } from 'wagmi'
import { parseAbiParameters, decodeAbiParameters, type Hash, getAddress } from 'viem'
import { l2PublicClient, l1PublicClient, config } from '@/lib/config'
import { L2_TO_L1_MESSAGE_PASSER_ABI, L2_TO_L1_MESSAGE_PASSER_ADDRESS } from '@/lib/contracts'
import { getWithdrawalStatus } from '@/lib/withdrawal-actions'
import type { WithdrawalData } from '@/lib/withdrawal-actions'
import { L1_ETH_BRIDGE_ABI } from '@/lib/contracts'

interface LatestWithdrawal {
  withdrawalData: WithdrawalData
  blockNumber: bigint
  transactionHash: Hash
  status: {
    isProven: boolean
    isFinalized: boolean
    provenAt: number | null
    proposalId: number | null
    canFinalize: boolean
  }
}

export function useLatestWithdrawal() {
  const { address } = useAccount()
  const [withdrawal, setWithdrawal] = useState<LatestWithdrawal | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!address) {
      setWithdrawal(null)
      setLoading(false)
      return
    }

    async function fetchLatestWithdrawal() {
      try {
        setLoading(true)
        setError(null)

        // Get the L2 bridge address from L1 contract and ensure checksummed format
        const l2BridgeAddress = getAddress(config.l2ETHBridgeAddress)
        const l1BridgeAddress = getAddress(config.l1ETHBridgeAddress)

        // Now use the checksummed addresses in the RPC filter
        const logs = await l2PublicClient.getLogs({
          address: L2_TO_L1_MESSAGE_PASSER_ADDRESS,
          event: {
            type: 'event',
            name: 'MessagePassed',
            inputs: L2_TO_L1_MESSAGE_PASSER_ABI.find(abi => abi.name === 'MessagePassed')!.inputs
          },
          args: {
            sender: l2BridgeAddress,
            target: l1BridgeAddress
          },
          fromBlock: 'earliest',
          toBlock: 'latest'
        })
        
        // Filter logs to only include withdrawals for the current user
        const userLogs = logs.filter(log => {
          try {
            const data = log.args.data!
            const [to] = decodeAbiParameters(
              parseAbiParameters('address, uint256'),
              data
            )
            return to.toLowerCase() === address?.toLowerCase()
          } catch {
            return false
          }
        })

        if (userLogs.length === 0) {
          setWithdrawal(null)
          setLoading(false)
          return
        }

        // Find the most recent non-finalized withdrawal
        let latestNonFinalizedLog = null
        
        for (let i = userLogs.length - 1; i >= 0; i--) {
          const log = userLogs[i]
          const withdrawalHash = log.args.withdrawalHash!
          
          // Check if this withdrawal is finalized
          const isFinalized = await l1PublicClient.readContract({
            address: config.l1ETHBridgeAddress,
            abi: L1_ETH_BRIDGE_ABI,
            functionName: 'finalized',
            args: [withdrawalHash]
          })
          
          if (!isFinalized) {
            latestNonFinalizedLog = log
            break
          }
        }
        
        if (!latestNonFinalizedLog) {
          // All withdrawals are finalized
          setWithdrawal(null)
          setLoading(false)
          return
        }

        // Use the latest non-finalized withdrawal
        const latestLog = latestNonFinalizedLog
        
        // Extract data from the log
        const nonce = latestLog.args.nonce!
        const value = latestLog.args.value!
        const data = latestLog.args.data!
        const withdrawalHash = latestLog.args.withdrawalHash!

        // Decode the withdrawal amount from the data field
        // The data contains encoded (address to, uint256 amount)
        const [to, amount] = decodeAbiParameters(
          parseAbiParameters('address, uint256'),
          data
        )

        const withdrawalData: WithdrawalData = {
          to,
          amount,
          nonce,
          withdrawalHash
        }

        // Get withdrawal status from L1
        const status = await getWithdrawalStatus(withdrawalHash)

        setWithdrawal({
          withdrawalData,
          blockNumber: latestLog.blockNumber,
          transactionHash: latestLog.transactionHash,
          status
        })
      } catch (err) {
        console.error('[useLatestWithdrawal] Error:', err)
        setError(err instanceof Error ? err.message : 'Failed to fetch withdrawal')
      } finally {
        setLoading(false)
      }
    }

    fetchLatestWithdrawal()
    
    // Poll every 10 seconds
    const interval = setInterval(fetchLatestWithdrawal, 10000)
    return () => clearInterval(interval)
  }, [address])

  return { withdrawal, loading, error }
}
