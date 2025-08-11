'use client'

import { useState, useEffect } from 'react'
import { WalletButton } from '@/components/wallet-button'
import { NetworkStatus } from '@/components/network-status'
import { WithdrawalWizard } from '@/components/withdrawal-wizard'
import { DepositWizard } from '@/components/deposit-wizard'
import { ContractsFooter } from '@/components/contracts-footer'
import { BridgeEducation } from '@/components/bridge-education'
import { config, l1PublicClient } from '@/lib/config'
import { L1_BRIDGE_ABI } from '@/lib/contracts'
import { Address } from 'viem'

export default function Home() {
  const [activeTab, setActiveTab] = useState<'deposit' | 'withdraw'>('deposit')
  const [ownerAddress, setOwnerAddress] = useState<Address | null>(null)
  
  // Check if bridge ownership is renounced
  useEffect(() => {
    async function checkOwner() {
      try {
        const owner = await l1PublicClient.readContract({
          address: config.l1BridgeAddress,
          abi: L1_BRIDGE_ABI,
          functionName: 'owner',
        }) as Address
        setOwnerAddress(owner)
      } catch (err) {
        console.error('Failed to fetch owner:', err)
      }
    }
    checkOwner()
  }, [])
  
  const isOwnershipRenounced = ownerAddress === '0x0000000000000000000000000000000000000000'
  
  return (
    <div className="min-h-dvh bg-gray-50 flex flex-col">
      {/* Header */}
      <header className="bg-white border-b border-gray-200">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="flex justify-between items-center h-16">
            <div className="flex items-center">
              <h1 className="text-xl font-bold text-gray-900">Facet Bluebird Bridge</h1>
            </div>
            <div className="flex items-center gap-4">
              <NetworkStatus />
              <WalletButton />
            </div>
          </div>
        </div>
      </header>

      {/* Main Content */}
      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-12">
        {/* Educational Section */}
        <BridgeEducation />

        {/* Bridge Interface */}
        <div className="text-center mb-8">
          <h3 className="text-2xl font-bold text-gray-900 mb-2">
            Bridge ETH ↔️ Bluebird WETH
          </h3>
          <p className="text-gray-600">
            Deposit to Bluebird and withdraw to L1 using ZK Fault Proofs
          </p>
        </div>

        {/* Tab Navigation */}
        <div className="flex justify-center mb-8">
          <div className="bg-white rounded-lg shadow-sm p-1 flex">
            <button
              onClick={() => setActiveTab('deposit')}
              className={`px-6 py-2 rounded-md font-medium transition-colors ${
                activeTab === 'deposit'
                  ? 'bg-blue-500 text-white'
                  : 'text-gray-600 hover:text-gray-900'
              }`}
            >
              Deposit
            </button>
            <button
              onClick={() => setActiveTab('withdraw')}
              className={`px-6 py-2 rounded-md font-medium transition-colors ${
                activeTab === 'withdraw'
                  ? 'bg-blue-500 text-white'
                  : 'text-gray-600 hover:text-gray-900'
              }`}
            >
              Withdraw
            </button>
          </div>
        </div>

        {/* Active Component */}
        {activeTab === 'deposit' ? <DepositWizard /> : <WithdrawalWizard />}
      </main>

      {/* Footer */}
      <ContractsFooter />
    </div>
  )
}