import type { Address, Chain, Client, Hex, Transport, StateOverride } from 'viem'
import type { OutputRootProof } from './types'
import { readContract } from 'viem/actions'
import { keccak256, encodeAbiParameters } from 'viem'

const rollupAbi = [
  {
    inputs: [{ name: 'id', type: 'uint256' }],
    name: 'getProposal',
    outputs: [
      {
        components: [
          { name: 'rootClaim', type: 'bytes32' },
          { name: 'proposer', type: 'address' },
          { name: 'l2BlockNumber', type: 'uint32' },
          { name: 'parentIndex', type: 'uint32' },
          { name: 'deadline', type: 'uint32' },
          { name: 'resolvedAt', type: 'uint64' },
          { name: 'proposalStatus', type: 'uint8' },
          { name: 'resolutionStatus', type: 'uint8' },
          { name: 'challenger', type: 'address' },
          { name: 'prover', type: 'address' },
        ],
        type: 'tuple',
      },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{ name: 'proposalId', type: 'uint256' }],
    name: 'proposalIsCanonical',
    outputs: [{ type: 'bool' }],
    stateMutability: 'view',
    type: 'function',
  },
] as const


export type FindCanonicalProposalParameters = {
  /** The output root proof to search for */
  outputRootProof: OutputRootProof
  /** Address of the Rollup contract */
  rollupAddress: Address
  /** Starting proposal ID to search from (default: 0) */
  startProposalId?: bigint
  /** Maximum number of proposals to search (default: 100) */
  maxProposals?: number
  /** State overrides for simulation */
  stateOverride?: StateOverride | undefined
}

export type FindCanonicalProposalReturnType = bigint | null

/**
 * Searches for a canonical proposal with the given output root in the OP-Succinct Rollup.
 *
 * @param client - Client to use
 * @param parameters - {@link FindCanonicalProposalParameters}
 * @returns The proposal ID if found, null otherwise. {@link FindCanonicalProposalReturnType}
 *
 * @example
 * import { createPublicClient, http } from 'viem'
 * import { mainnet } from 'viem/chains'
 * import { findCanonicalProposal } from 'viem/op-stack'
 *
 * const client = createPublicClient({
 *   chain: mainnet,
 *   transport: http(),
 * })
 *
 * const proposalId = await findCanonicalProposal(client, {
 *   outputRootProof: {
 *     version: '0x0000000000000000000000000000000000000000000000000000000000000000',
 *     stateRoot: '0x...',
 *     messagePasserStorageRoot: '0x...',
 *     latestBlockhash: '0x...',
 *   },
 *   rollupAddress: '0x...',
 * })
 */
export async function findCanonicalProposal<chain extends Chain | undefined>(
  client: Client<Transport, chain>,
  parameters: FindCanonicalProposalParameters,
): Promise<FindCanonicalProposalReturnType> {
  const {
    outputRootProof,
    rollupAddress,
    startProposalId = 0n,
    maxProposals = 100,
    stateOverride,
  } = parameters

  // Calculate the target root we're looking for
  const targetRoot = keccak256(
    encodeAbiParameters(
      [
        { type: 'bytes32' },
        { type: 'bytes32' },
        { type: 'bytes32' },
        { type: 'bytes32' },
      ],
      [
        outputRootProof.version,
        outputRootProof.stateRoot,
        outputRootProof.messagePasserStorageRoot,
        outputRootProof.latestBlockhash,
      ]
    )
  )

  // Search through proposals
  for (let i = 0; i < maxProposals; i++) {
    const proposalId = startProposalId + BigInt(i)
    
    try {
      // Get proposal details
      const proposal = await readContract(client, {
        address: rollupAddress,
        abi: rollupAbi,
        functionName: 'getProposal',
        args: [proposalId],
        stateOverride,
      })
      
      // Check if root matches
      if (proposal.rootClaim.toLowerCase() === targetRoot.toLowerCase()) {
        // Verify it's canonical
        const isCanonical = await readContract(client, {
          address: rollupAddress,
          abi: rollupAbi,
          functionName: 'proposalIsCanonical',
          args: [proposalId],
          stateOverride,
        })
        
        if (isCanonical) {
          return proposalId
        }
      }
    } catch (error) {
      // Proposal doesn't exist, stop searching
      break
    }
  }
  
  return null
}