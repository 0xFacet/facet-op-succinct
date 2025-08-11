'use client'

import { useState, useEffect } from 'react'
import { useAccount } from 'wagmi'
import { InitiateStep } from './initiate-step'
import { WaitProposalStep } from './wait-proposal-step'
import { ProveStep } from './prove-step'
import { FinalizeStep } from './finalize-step'
import { useLatestWithdrawal } from '@/hooks/useLatestWithdrawal'
import { findCanonicalProposal } from '@/lib/withdrawal-actions'
import type { WithdrawalData } from '@/lib/withdrawal-actions'
import type { OutputRootProof } from '@/lib/actions/types'

export type WizardStep = 'initiate' | 'wait-proposal' | 'prove' | 'finalize'

interface WithdrawalState {
  step: WizardStep
  txHash?: string
  withdrawalData?: WithdrawalData
  proposalId?: number
  isProven?: boolean
  isFinalized?: boolean
  provenAt?: number
}

export function WithdrawalWizard() {
  const { address, isConnected } = useAccount()
  const [state, setState] = useState<WithdrawalState>({ step: 'initiate' })
  const { withdrawal, loading: withdrawalLoading } = useLatestWithdrawal()

  // Derive state from on-chain data
  useEffect(() => {
    if (!withdrawal || withdrawalLoading) return

    async function updateStateFromChain() {
      try {
        if (!withdrawal) return
        const { withdrawalData, status } = withdrawal
        
        // If finalized, show as complete
        if (status.isFinalized) {
          setState({
            step: 'finalize',
            withdrawalData,
            isFinalized: true,
            isProven: true,
            provenAt: status.provenAt || undefined
          })
          return
        }

        // If proven, show finalize step
        if (status.isProven) {
          setState({
            step: 'finalize',
            withdrawalData,
            isProven: true,
            provenAt: status.provenAt || undefined,
            proposalId: status.proposalId || undefined
          })
          return
        }

        // Since withdrawal exists, we're at least waiting for proposal
        setState({
          step: 'wait-proposal',
          withdrawalData,
          txHash: withdrawal.transactionHash
        })
      } catch (err) {
        console.error('Failed to update state from chain:', err)
      }
    }

    updateStateFromChain()
  }, [withdrawal, withdrawalLoading])

  const updateState = (updates: Partial<WithdrawalState>) => {
    setState(prev => ({ ...prev, ...updates }))
  }

  const reset = () => {
    setState({ step: 'initiate' })
  }

  if (!isConnected) {
    return (
      <div className="max-w-2xl mx-auto p-8 bg-white rounded-lg shadow-sm">
        <h2 className="text-2xl font-bold mb-4">Withdraw from Facet</h2>
        <p className="text-gray-600 mb-6">
          Connect your wallet to start the withdrawal process.
        </p>
      </div>
    )
  }

  return (
    <div className="max-w-2xl mx-auto p-4 sm:p-6 lg:p-8 bg-white rounded-lg shadow-sm">
      <h2 className="text-2xl font-bold mb-6">Withdraw from Facet</h2>
      
      {/* Progress indicator */}
      <div className="mb-8">
        <div className="flex items-center justify-between mb-2">
          <StepIndicator label="Initiate" active={state.step === 'initiate'} completed={state.step !== 'initiate'} />
          <div className={`flex-1 h-1 mx-2 ${state.step !== 'initiate' ? 'bg-blue-500' : 'bg-gray-200'}`} />
          <StepIndicator label="Wait for Proposal" active={state.step === 'wait-proposal'} completed={['prove', 'finalize'].includes(state.step)} />
          <div className={`flex-1 h-1 mx-2 ${['prove', 'finalize'].includes(state.step) ? 'bg-blue-500' : 'bg-gray-200'}`} />
          <StepIndicator label="Prove" active={state.step === 'prove'} completed={state.step === 'finalize'} />
          <div className={`flex-1 h-1 mx-2 ${state.step === 'finalize' ? 'bg-blue-500' : 'bg-gray-200'}`} />
          <StepIndicator label="Finalize" active={state.step === 'finalize'} completed={state.isFinalized || false} />
        </div>
      </div>

      {/* Current step */}
      <div className="mb-6">
        {state.step === 'initiate' && (
          <InitiateStep onNext={(txHash, withdrawalData) => {
            updateState({ 
              step: 'wait-proposal', 
              txHash, 
              withdrawalData 
            })
          }} />
        )}
        
        {state.step === 'wait-proposal' && state.withdrawalData && (
          <WaitProposalStep 
            withdrawalData={state.withdrawalData}
            txHash={state.txHash}
            onProposalFound={(proposalId) => {
              updateState({ step: 'prove', proposalId })
            }}
          />
        )}
        
        {state.step === 'prove' && state.withdrawalData && state.proposalId !== undefined && (
          <ProveStep
            withdrawalData={state.withdrawalData}
            proposalId={state.proposalId}
            onProven={(provenAt) => {
              updateState({ step: 'finalize', isProven: true, provenAt })
            }}
          />
        )}
        
        {state.step === 'finalize' && state.withdrawalData && state.provenAt && (
          <FinalizeStep
            withdrawalData={state.withdrawalData}
            provenAt={state.provenAt}
            onFinalized={() => {
              updateState({ isFinalized: true })
              reset()
            }}
          />
        )}
      </div>

      {/* Educational Information */}
      <div className="mt-8 p-4 bg-blue-50 rounded-lg border border-blue-200">
        <h3 className="text-sm font-semibold text-blue-900 mb-2">Understanding ZK-Proven Withdrawals</h3>
        <div className="space-y-2 text-xs text-blue-800">
          <p>
            Unlike traditional bridges that rely on trusted operators or time delays, this bridge uses 
            Zero-Knowledge proofs to cryptographically verify every withdrawal.
          </p>
          <div className="mt-2">
            <strong>The Process:</strong>
            <ol className="list-decimal list-inside ml-2 mt-1 space-y-1">
              <li>Initiate withdrawal on L2 (burns your BBWETH)</li>
              <li>Wait for the L2 state to be proposed to L1</li>
              <li>Generate a ZK proof that your withdrawal is valid</li>
              <li>Submit the proof to unlock your ETH on L1</li>
            </ol>
          </div>
          <p className="mt-2 p-2 bg-blue-100 rounded">
            <strong>Note:</strong> Because ownership is renounced, no one can pause withdrawals, 
            blacklist addresses, or interfere with the process. Your withdrawal is guaranteed by mathematics.
          </p>
        </div>
      </div>
    </div>
  )
}

function StepIndicator({ label, active, completed }: { label: string; active: boolean; completed: boolean }) {
  return (
    <div className="flex flex-col items-center">
      <div className={`w-8 h-8 rounded-full flex items-center justify-center text-sm font-medium
        ${completed ? 'bg-blue-500 text-white' : active ? 'bg-blue-100 text-blue-600 ring-2 ring-blue-500' : 'bg-gray-200 text-gray-500'}`}>
        {completed ? '✓' : label.charAt(0)}
      </div>
      <span className={`text-xs mt-1 text-center max-w-[60px] sm:max-w-none ${active ? 'text-blue-600 font-medium' : 'text-gray-500'}`}>
        {label}
      </span>
    </div>
  )
}