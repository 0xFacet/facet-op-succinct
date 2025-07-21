import type { Address, Chain, Client, Hex, Transport, StateOverride } from 'viem'
import type { Proposal } from './types'
import { readContract } from 'viem/actions'

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
  {
    inputs: [{ name: 'l2BlockNumber', type: 'uint256' }],
    name: 'canonicalProposalIdFor',
    outputs: [{ type: 'uint32' }],
    stateMutability: 'view',
    type: 'function',
  },
] as const


export type GetCanonicalProposalParameters = {
  /** L2 block number to get the canonical proposal for. */
  l2BlockNumber: bigint
  /** Address of the Rollup contract. */
  rollupAddress: Address
  /** State overrides for simulation. */
  stateOverride?: StateOverride | undefined
}

export type GetCanonicalProposalReturnType = {
  proposalId: number
  proposal: Proposal
}

/**
 * Gets the canonical proposal for a given L2 block number from the OP-Succinct Rollup contract.
 *
 * @param client - Client to use
 * @param parameters - {@link GetCanonicalProposalParameters}
 * @returns The canonical proposal and its ID. {@link GetCanonicalProposalReturnType}
 *
 * @example
 * import { createPublicClient, http } from 'viem'
 * import { mainnet } from 'viem/chains'
 * import { getCanonicalProposal } from 'viem/op-stack'
 *
 * const client = createPublicClient({
 *   chain: mainnet,
 *   transport: http(),
 * })
 *
 * const result = await getCanonicalProposal(client, {
 *   l2BlockNumber: 1234567n,
 *   rollupAddress: '0x...',
 * })
 */
export async function getCanonicalProposal<chain extends Chain | undefined>(
  client: Client<Transport, chain>,
  parameters: GetCanonicalProposalParameters,
): Promise<GetCanonicalProposalReturnType> {
  const { l2BlockNumber, rollupAddress, stateOverride } = parameters

  // Get the canonical proposal ID
  const proposalId = await readContract(client, {
    address: rollupAddress,
    abi: rollupAbi,
    functionName: 'canonicalProposalIdFor',
    args: [l2BlockNumber],
    stateOverride,
  })

  // Get the proposal details
  const proposal = await readContract(client, {
    address: rollupAddress,
    abi: rollupAbi,
    functionName: 'getProposal',
    args: [BigInt(proposalId)],
    stateOverride,
  })

  return {
    proposalId,
    proposal: proposal as Proposal,
  }
}