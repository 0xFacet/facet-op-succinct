'use client'

import { useState, useEffect } from 'react'
import { config, l1PublicClient } from '@/lib/config'
import { ROLLUP_ABI } from '@/lib/contracts'

interface RollupParams {
  aggVkey: string
  rangeVkeyCommitment: string
  rollupConfigHash: string
}

export function BridgeEducation() {
  const [showEducation, setShowEducation] = useState(true)
  const [rollupParams, setRollupParams] = useState<RollupParams | null>(null)
  const [showParams, setShowParams] = useState(false)
  
  // Fetch immutable rollup parameters
  useEffect(() => {
    async function fetchParams() {
      try {
        const [aggVkey, rangeVkeyCommitment, rollupConfigHash] = await Promise.all([
          l1PublicClient.readContract({
            address: config.rollupAddress,
            abi: ROLLUP_ABI as any,
            functionName: 'AGG_VKEY',
            args: [],
          }),
          l1PublicClient.readContract({
            address: config.rollupAddress,
            abi: ROLLUP_ABI as any,
            functionName: 'RANGE_VKEY_COMMITMENT',
            args: [],
          }),
          l1PublicClient.readContract({
            address: config.rollupAddress,
            abi: ROLLUP_ABI as any,
            functionName: 'ROLLUP_CONFIG_HASH',
            args: [],
          }),
        ])
        
        setRollupParams({
          aggVkey: aggVkey as string,
          rangeVkeyCommitment: rangeVkeyCommitment as string,
          rollupConfigHash: rollupConfigHash as string,
        })
      } catch (err) {
        console.error('Failed to fetch rollup parameters:', err)
      }
    }
    fetchParams()
  }, [])
  
  return (
    <div className="mb-12 text-center">
      <h2 className="text-4xl font-bold text-gray-900 mb-4">
        Facet Bluebird Bridge
      </h2>
      <p className="text-xl text-gray-700 mb-2 max-w-3xl mx-auto">
        A trustless WETH bridge for the Bluebird fork of the Facet rollup
      </p>
      
      {/* Key Features Cards */}
      <div className="grid md:grid-cols-3 gap-6 mb-8 max-w-5xl mx-auto">
        <div className="bg-white p-6 rounded-xl shadow-sm border border-gray-200">
          <div className="w-12 h-12 bg-green-100 rounded-lg flex items-center justify-center mx-auto mb-4">
            <svg className="w-6 h-6 text-green-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z" />
            </svg>
          </div>
          <h3 className="font-semibold text-gray-900 mb-2">Trustless*</h3>
          <p className="text-sm text-gray-600">
            Ownership renounced. No admin keys, no governance. 
            Security depends only on ZK proof system and smart contract correctness.
          </p>
        </div>
        
        <div className="bg-white p-6 rounded-xl shadow-sm border border-gray-200">
          <div className="w-12 h-12 bg-blue-100 rounded-lg flex items-center justify-center mx-auto mb-4">
            <svg className="w-6 h-6 text-blue-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
          </div>
          <h3 className="font-semibold text-gray-900 mb-2">Immutable Rules</h3>
          <p className="text-sm text-gray-600">
            The proof system (Rollup.sol) proves one specific state transition function forever. 
            The rules can never change.
          </p>
        </div>
        
        <div className="bg-white p-6 rounded-xl shadow-sm border border-gray-200">
          <div className="w-12 h-12 bg-amber-100 rounded-lg flex items-center justify-center mx-auto mb-4">
            <svg className="w-6 h-6 text-amber-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
            </svg>
          </div>
          <h3 className="font-semibold text-gray-900 mb-2">No Training Wheels</h3>
          <p className="text-sm text-gray-600">
            This deployment has no root blacklisting capability. 
            Once a withdrawal is proven, it cannot be stopped.
          </p>
        </div>
      </div>
      
      {/* Detailed Explanation Box */}
      {showEducation && (
        <div className="bg-blue-50 border border-blue-200 rounded-xl p-6 max-w-4xl mx-auto text-left mb-8">
          <div className="flex justify-between items-start mb-4">
            <h3 className="text-lg font-semibold text-blue-900">Read Before Using This Bridge!</h3>
            <button
              onClick={() => setShowEducation(false)}
              className="text-blue-600 hover:text-blue-800"
              aria-label="Close"
            >
              <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
          
          <div className="space-y-4 text-sm text-blue-800">
            <div>
              <h4 className="font-semibold mb-1">About the Bridge Code</h4>
              <p>
                This bridge is deployed from the{' '}
                <a 
                  href="https://github.com/0xFacet/zk-fault-proofs" 
                  target="_blank" 
                  rel="noopener noreferrer"
                  className="underline hover:text-blue-900"
                >
                  Facet ZK Fault Proofs repository
                </a>, 
                which implements a ZK fault proof system for the Facet rollup. The bridge contracts 
                support optional "training wheels" features like root blacklisting, but this deployment 
                has ownership renounced—those safety features are permanently disabled.
              </p>
            </div>
            
            <div>
              <h4 className="font-semibold mb-1">Fork Binding</h4>
              <p className="mb-3">
                <strong>"Bluebird" is the name of a specific Facet fork.</strong> The immutable parameters 
                in the Rollup contract cryptographically define this fork's state transition rules. If Facet creates a new fork with different rules, 
                those parameters won't match, and this bridge will remain locked to Bluebird's original rules forever.
              </p>
              
              <button
                onClick={() => setShowParams(!showParams)}
                className="text-xs text-blue-700 hover:text-blue-900 underline mb-2"
              >
                {showParams ? 'Hide' : 'Show'} Cryptographic Parameters
              </button>
              
              {showParams && rollupParams && (
                <div className="mt-3 p-3 bg-amber-50 rounded-lg border border-amber-200">
                  <div className="space-y-2">
                    <div>
                      <div className="text-xs font-medium text-amber-800">AGG_VKEY</div>
                      <code className="text-xs text-amber-900 font-mono break-all block bg-amber-100 p-1 rounded mt-1">
                        {rollupParams.aggVkey}
                      </code>
                    </div>
                    <div>
                      <div className="text-xs font-medium text-amber-800">RANGE_VKEY_COMMITMENT</div>
                      <code className="text-xs text-amber-900 font-mono break-all block bg-amber-100 p-1 rounded mt-1">
                        {rollupParams.rangeVkeyCommitment}
                      </code>
                    </div>
                    <div>
                      <div className="text-xs font-medium text-amber-800">ROLLUP_CONFIG_HASH</div>
                      <code className="text-xs text-amber-900 font-mono break-all block bg-amber-100 p-1 rounded mt-1">
                        {rollupParams.rollupConfigHash}
                      </code>
                    </div>
                  </div>
                  <p className="text-xs text-amber-700 mt-3 italic">
                    These values are permanently hardcoded in the Rollup contract and define exactly which fork this bridge serves.
                  </p>
                </div>
              )}
            </div>
            
            <div>
              <h4 className="font-semibold mb-1">Trust Dependencies</h4>
              <ul className="list-disc list-inside space-y-1 ml-2">
                <li>The SP1 ZK proof system must correctly verify state transitions</li>
                <li>The bridge and Rollup.sol smart contract implementations must be bug-free</li>
              </ul>
            </div>
            
            <div>
              <h4 className="font-semibold mb-1">What This Means for You</h4>
              <ul className="list-disc list-inside space-y-1 ml-2">
                <li>If there is a bug, no admin can step in to fix it and recover your funds</li>
                <li>You may use the Bluebird fork of Facet forever. However, if you choose to use a different fork <b>you must withdraw from this bridge and redeposit into a bridge that supports the new fork.</b></li>
              </ul>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}