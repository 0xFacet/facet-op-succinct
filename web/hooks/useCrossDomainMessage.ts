import { useState, useEffect, useRef } from 'react'
import { 
  type Address,
  decodeAbiParameters,
  parseAbiParameters
} from 'viem'
import { usePublicClient } from 'wagmi'
import { config } from '@/lib/config'
import { L2_TO_L1_MESSAGE_PASSER_ABI, L2_TO_L1_MESSAGE_PASSER_ADDRESS } from '@/lib/contracts'
import { computeWithdrawalHash, type WithdrawalData } from '@/lib/withdrawal-actions'

interface UseCrossDomainMessageParams {
  expectedAmount: bigint
  userAddress: Address
  enabled?: boolean
}

interface UseCrossDomainMessageReturn {
  withdrawalData: WithdrawalData | null
  isPolling: boolean
  error: Error | null
  scanProgress: {
    currentBlock: bigint | null
    elapsedSeconds: number
  }
}

export function useCrossDomainMessage({
  expectedAmount,
  userAddress,
  enabled = true
}: UseCrossDomainMessageParams): UseCrossDomainMessageReturn {
  const [withdrawalData, setWithdrawalData] = useState<WithdrawalData | null>(null)
  const [isPolling, setIsPolling] = useState(false)
  const [error, setError] = useState<Error | null>(null)
  const [scanProgress, setScanProgress] = useState<{ currentBlock: bigint | null, elapsedSeconds: number }>({ 
    currentBlock: null, 
    elapsedSeconds: 0 
  })
  
  const l2PublicClient = usePublicClient({ chainId: config.l2ChainId })
  const abortControllerRef = useRef<AbortController | null>(null)
  const startTimeRef = useRef<number>(0)
  const lastCheckedBlockRef = useRef<bigint>(0n)

  useEffect(() => {
    if (!enabled || !l2PublicClient || withdrawalData) return

    // Create abort controller for cleanup
    abortControllerRef.current = new AbortController()
    const { signal } = abortControllerRef.current
    
    let timeoutId: ReturnType<typeof setTimeout> | null = null
    let attempt = 0
    
    const startPolling = async () => {
      try {
        setIsPolling(true)
        setError(null)
        startTimeRef.current = Date.now()
        
        // Get the starting L2 block after L1 confirmation
        const startBlock = await l2PublicClient.getBlockNumber()
        lastCheckedBlockRef.current = startBlock
        
        console.log('[MessagePassed Poll] Starting from L2 block:', startBlock)
        
        const pollForEvent = async (): Promise<void> => {
          if (signal.aborted) return
          
          const elapsed = Date.now() - startTimeRef.current
          const elapsedSeconds = Math.floor(elapsed / 1000)
          
          // 5 minute timeout
          if (elapsed > 300000) {
            throw new Error('Timeout waiting for withdrawal event after 5 minutes')
          }
          
          try {
            const currentBlock = await l2PublicClient.getBlockNumber()
            
            setScanProgress({ currentBlock, elapsedSeconds })
            
            console.log('[MessagePassed Poll]', {
              attempt,
              fromBlock: lastCheckedBlockRef.current,
              toBlock: currentBlock,
              elapsed: `${elapsedSeconds}s`
            })
            
            const logs = await l2PublicClient.getLogs({
              address: L2_TO_L1_MESSAGE_PASSER_ADDRESS,
              event: {
                type: 'event',
                name: 'MessagePassed',
                inputs: L2_TO_L1_MESSAGE_PASSER_ABI.find(abi => abi.name === 'MessagePassed')!.inputs
              },
              fromBlock: lastCheckedBlockRef.current,
              toBlock: currentBlock
            })
            
            // Find matching withdrawal by computing hash
            for (const log of logs) {
              const { nonce, withdrawalHash, data } = log.args
              if (nonce === undefined || withdrawalHash === undefined || data === undefined) continue
              
              // Decode the withdrawal data to check if it's for this user
              const [to, amount] = decodeAbiParameters(
                parseAbiParameters('address, uint256'),
                data
              )
              
              // Verify this is the user's withdrawal
              if (to.toLowerCase() === userAddress.toLowerCase() && amount === expectedAmount) {
                // Compute expected hash to double-check
                const calculatedHash = computeWithdrawalHash({
                  nonce: nonce,
                  l2Bridge: config.l2BridgeAddress,
                  l1Bridge: config.l1BridgeAddress,
                  to: userAddress,
                  amount: expectedAmount
                })
                
                if (withdrawalHash.toLowerCase() === calculatedHash.toLowerCase()) {
                  console.log('[MessagePassed Poll] Found matching withdrawal:', {
                    nonce: nonce.toString(),
                    hash: withdrawalHash,
                    blockNumber: log.blockNumber
                  })
                  
                  // Wait until the log has two confirmations
                  while (!signal.aborted) {
                    const currentBlock = await l2PublicClient.getBlockNumber()
                    if (currentBlock >= log.blockNumber + 2n) break
                    await new Promise(r => setTimeout(r, 1000))
                  }
                  
                  const withdrawalData: WithdrawalData = {
                    to,
                    amount,
                    nonce: nonce,
                    withdrawalHash: withdrawalHash
                  }
                  
                  setWithdrawalData(withdrawalData)
                  setIsPolling(false)
                  return
                }
              }
            }
            
            // Advance window & manage back-off
            if (currentBlock > lastCheckedBlockRef.current) {
              // Chain moved forward → shift the window and reset back-off
              lastCheckedBlockRef.current = currentBlock + 1n
              attempt = 0
            } else {
              // No progress → increase back-off delay
              attempt++
            }
            
            const delay = Math.min(1000 * Math.pow(2, attempt), 8000)
            
            if (!signal.aborted) {
              timeoutId = setTimeout(() => pollForEvent(), delay)
            }
            
          } catch (err) {
            if (signal.aborted || (err instanceof Error && err.name === 'AbortError')) return
            
            console.error('[MessagePassed Poll] Error:', err)
            
            // For RPC errors, retry with backoff
            const errorMessage = err instanceof Error ? err.message : String(err)
            if (errorMessage.includes('RPC') || errorMessage.includes('network')) {
              attempt++
              const delay = Math.min(1000 * Math.pow(2, attempt), 8000)
              if (!signal.aborted) {
                timeoutId = setTimeout(() => pollForEvent(), delay)
              }
            } else {
              throw err
            }
          }
        }
        
        // Start polling
        await pollForEvent()
        
      } catch (err) {
        if (!signal.aborted) {
          setError(err instanceof Error ? err : new Error('Failed to get withdrawal event'))
          setIsPolling(false)
        }
      }
    }
    
    startPolling()
    
    // Cleanup function
    return () => {
      if (abortControllerRef.current) {
        abortControllerRef.current.abort()
      }
      if (timeoutId) {
        clearTimeout(timeoutId)
      }
      setIsPolling(false)
    }
  }, [enabled, l2PublicClient, expectedAmount, userAddress, withdrawalData])

  return {
    withdrawalData,
    isPolling,
    error,
    scanProgress
  }
}