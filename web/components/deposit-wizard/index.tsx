'use client'

import { useState, useEffect } from 'react'
import { useAccount, useBalance, useWalletClient, useChainId, useSwitchChain } from 'wagmi'
import { formatEther, parseEther } from 'viem'
import { config, l1PublicClient, l2PublicClient } from '@/lib/config'
import { sendFacetTransaction } from '@0xfacet/sdk/viem'

const ERC20_ABI = [
  {
    inputs: [{ name: 'owner', type: 'address' }],
    name: 'balanceOf',
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },
] as const

export function DepositWizard() {
  const { address, isConnected } = useAccount()
  const { data: walletClient } = useWalletClient()
  const chainId = useChainId()
  const { switchChain } = useSwitchChain()
  
  const [amount, setAmount] = useState('')
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [txHash, setTxHash] = useState<string | null>(null)
  const [txStatus, setTxStatus] = useState<'pending' | 'confirmed' | null>(null)
  
  const isOnL1 = chainId === config.l1ChainId
  
  // Get L1 balance
  const { data: l1Balance } = useBalance({
    address,
    chainId: config.l1ChainId,
  })
  
  // Get L2 ERC20 balance
  const [l2Balance, setL2Balance] = useState<bigint>(0n)
  
  useEffect(() => {
    async function fetchL2Balance() {
      if (!address) return
      
      try {
        const balance = await l2PublicClient.readContract({
          address: config.l2ETHBridgeAddress,
          abi: ERC20_ABI,
          functionName: 'balanceOf',
          args: [address]
        })
        setL2Balance(balance)
      } catch (err) {
        console.error('Failed to fetch L2 balance:', err)
      }
    }
    
    fetchL2Balance()
    const interval = setInterval(fetchL2Balance, 5000) // Poll every 5 seconds
    return () => clearInterval(interval)
  }, [address])
  
  const handleDeposit = async () => {
    if (!walletClient || !address) {
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
      const value = parseEther(amount)
      
      // Send ETH to L1 bridge - it has a fallback that will handle the deposit
      const hash = await walletClient.sendTransaction({
        to: config.l1ETHBridgeAddress,
        value,
      })
      
      setTxHash(hash)
      setTxStatus('pending')
      
      // Wait for confirmation
      const receipt = await l1PublicClient.waitForTransactionReceipt({ hash })
      
      if (receipt.status === 'success') {
        setTxStatus('confirmed')
        setAmount('')
        // Clear the transaction after showing success for a few seconds
        setTimeout(() => {
          setTxHash(null)
          setTxStatus(null)
        }, 5000)
        // The L2 balance will update via polling
      } else {
        throw new Error('Transaction failed')
      }
    } catch (err) {
      console.error('Deposit error:', err)
      setError(err instanceof Error ? err.message : 'Failed to deposit')
    } finally {
      setLoading(false)
    }
  }
  
  if (!isConnected) {
    return (
      <div className="max-w-2xl mx-auto p-8 bg-white rounded-lg shadow-sm">
        <h2 className="text-2xl font-bold mb-4">Deposit to Facet</h2>
        <p className="text-gray-600 mb-6">
          Connect your wallet to deposit ETH from Sepolia to Facet L2.
        </p>
      </div>
    )
  }
  
  return (
    <div className="max-w-2xl mx-auto p-8 bg-white rounded-lg shadow-sm">
      <h2 className="text-2xl font-bold text-gray-900 mb-6">Deposit ETH to Facet</h2>
      
      {/* Balance Display */}
      <div className="grid grid-cols-2 gap-4 mb-6">
        <div className="p-4 bg-gray-50 rounded-lg">
          <p className="text-sm font-medium text-gray-700">L1 Balance (Sepolia)</p>
          <p className="text-lg font-semibold text-gray-900">
            {l1Balance ? formatEther(l1Balance.value) : '0'} ETH
          </p>
        </div>
        <div className="p-4 bg-blue-50 rounded-lg">
          <p className="text-sm font-medium text-gray-700">L2 Balance (Facet)</p>
          <p className="text-lg font-semibold text-gray-900">
            {formatEther(l2Balance)} FFB
          </p>
          <p className="text-xs text-gray-600 mt-1">ERC20: {config.l2ETHBridgeAddress.slice(0, 6)}...{config.l2ETHBridgeAddress.slice(-4)}</p>
        </div>
      </div>
      
      {!isOnL1 && (
        <div className="mb-4 p-4 bg-orange-50 border border-orange-200 rounded-lg">
          <p className="text-sm text-orange-800">
            You need to be on Sepolia to deposit. 
            <button
              onClick={() => switchChain({ chainId: config.l1ChainId })}
              className="ml-2 text-orange-600 underline hover:text-orange-700"
            >
              Switch to Sepolia
            </button>
          </p>
        </div>
      )}
      
      {/* Deposit Form */}
      <div className="space-y-4">
        <div>
          <label htmlFor="amount" className="block text-sm font-medium text-gray-800 mb-2">
            Amount to Deposit
          </label>
          <div className="relative">
            <input
              id="amount"
              type="number"
              step="0.001"
              min="0"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              placeholder="0.01"
              className="w-full text-gray-800 px-3 py-2 pr-12 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
              disabled={loading || !isOnL1}
            />
            <span className="absolute right-3 top-2.5 text-gray-600 font-medium">ETH</span>
          </div>
        </div>
        
        {error && (
          <div className="p-3 bg-red-50 border border-red-200 rounded-lg">
            <p className="text-sm text-red-600">{error}</p>
          </div>
        )}
        
        {txHash && (
          <div className={`p-3 border rounded-lg ${
            txStatus === 'confirmed' 
              ? 'bg-green-50 border-green-200' 
              : 'bg-blue-50 border-blue-200'
          }`}>
            <p className={`text-sm ${
              txStatus === 'confirmed' ? 'text-green-800' : 'text-blue-800'
            }`}>
              {txStatus === 'pending' && '⏳ Transaction pending... Hash: '}
              {txStatus === 'confirmed' && '✅ Transaction confirmed! Hash: '}
              {txHash.slice(0, 10)}...{txHash.slice(-8)}
            </p>
            {txStatus === 'pending' && (
              <p className="text-xs text-blue-600 mt-1">Waiting for confirmation...</p>
            )}
            {txStatus === 'confirmed' && (
              <p className="text-xs text-green-600 mt-1">Your L2 balance will update shortly.</p>
            )}
          </div>
        )}
        
        <button
          onClick={handleDeposit}
          disabled={loading || !amount || !isOnL1}
          className="w-full py-2 px-4 bg-blue-500 text-white rounded-lg hover:bg-blue-600 disabled:bg-gray-300 disabled:cursor-not-allowed transition-colors"
        >
          {loading ? 'Depositing...' : 'Deposit to L2'}
        </button>
      </div>
      
      <div className="mt-6 p-4 bg-gray-50 rounded-lg">
        <h3 className="text-sm font-medium text-gray-800 mb-2">How it works</h3>
        <p className="text-xs text-gray-700">
          When you deposit ETH, it's sent to the L1 bridge contract which automatically 
          credits your account with wrapped FFB on Facet L2. Your L2 balance will update within a few seconds.
        </p>
      </div>
    </div>
  )
}