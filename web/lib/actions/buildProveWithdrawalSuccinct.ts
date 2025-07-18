import type { Address, Chain, Client, Hex, Transport, StateOverride } from 'viem'
import type { ProveWithdrawalSuccinctParameters } from './proveWithdrawalSuccinct'
import type { OutputRootProof } from './types'

import { getBlock, getProof, readContract } from 'viem/actions'
import { keccak256, encodeAbiParameters } from 'viem'

const l1EthBridgeAbi = [
  {
    inputs: [],
    name: 'l2Bridge',
    outputs: [{ type: 'address' }],
    stateMutability: 'view',
    type: 'function',
  },
] as const

export interface BuildProveWithdrawalSuccinctParameters {
  /** Recipient address on L1. */
  to: Address
  /** Amount to withdraw. */
  amount: bigint
  /** Withdrawal nonce. */
  nonce: bigint
  /** ID of the canonical proposal to prove the withdrawal against. */
  proposalId: bigint
  /** The output root from the proposal. */
  outputRoot: Hex
  /** The L2 block number of the proposal. */
  l2BlockNumber: bigint
  /** Address of the L1 ETH bridge contract. */
  bridgeAddress: Address
  /** L2 client to fetch proof data from. */
  l2Client: Client<Transport, Chain>
  /** State overrides for simulation. */
  stateOverride?: StateOverride | undefined
}

export interface BuildProveWithdrawalSuccinctReturnType {
  to: Address
  amount: bigint
  nonce: bigint
  proposalId: bigint
  outputRootProof: OutputRootProof
  withdrawalProof: readonly Hex[]
  bridgeAddress: Address
}

/**
 * Builds parameters for proving a withdrawal on an OP-Succinct L1 ETH Bridge.
 *
 * @param client - L1 client to use for fetching bridge configuration
 * @param parameters - {@link BuildProveWithdrawalSuccinctParameters}
 * @returns Parameters for calling proveWithdrawal. {@link BuildProveWithdrawalSuccinctReturnType}
 *
 * @example
 * import { createPublicClient, http } from 'viem'
 * import { mainnet, optimism } from 'viem/chains'
 * import { buildProveWithdrawalSuccinct } from 'viem/op-stack'
 *
 * const l1Client = createPublicClient({
 *   chain: mainnet,
 *   transport: http(),
 * })
 *
 * const l2Client = createPublicClient({
 *   chain: optimism,
 *   transport: http(),
 * })
 *
 * const args = await buildProveWithdrawalSuccinct(l1Client, {
 *   to: '0x...',
 *   amount: 1000000000000000000n,
 *   nonce: 1n,
 *   proposalId: 123n,
 *   outputRoot: '0x...',
 *   l2BlockNumber: 1234567n,
 *   bridgeAddress: '0x...',
 *   l2Client,
 * })
 */
export async function buildProveWithdrawalSuccinct<
  chain extends Chain | undefined,
>(
  client: Client<Transport, chain>,
  parameters: BuildProveWithdrawalSuccinctParameters,
): Promise<BuildProveWithdrawalSuccinctReturnType> {
  const {
    to,
    amount,
    nonce,
    proposalId,
    outputRoot,
    l2BlockNumber,
    bridgeAddress,
    l2Client,
    stateOverride,
  } = parameters

  // L2ToL1MessagePasser address is constant across OP Stack chains
  const l2ToL1MessagePasser = '0x4200000000000000000000000000000000000016' as const

  // Get the L2 bridge address from L1 bridge
  const l2Bridge = await readContract(client, {
    address: bridgeAddress,
    abi: l1EthBridgeAbi,
    functionName: 'l2Bridge',
    stateOverride,
  })

  // Get the L2 block
  const l2Block = await getBlock(l2Client, {
    blockNumber: l2BlockNumber,
  })

  // Encode withdrawal data
  const data = encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }],
    [to, amount]
  )

  // Compute the withdrawal hash
  const withdrawalHash = keccak256(
    encodeAbiParameters(
      [
        { type: 'uint256' },
        { type: 'address' },
        { type: 'address' },
        { type: 'uint256' },
        { type: 'uint256' },
        { type: 'bytes' },
      ],
      [nonce, l2Bridge, bridgeAddress, 0n, 0n, data]
    )
  )

  // Compute the storage slot for the withdrawal
  const storageKey = keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'uint256' }],
      [withdrawalHash, 0n] // slot 0
    )
  )

  // Get the proof for the withdrawal
  const proof = await getProof(l2Client, {
    address: l2ToL1MessagePasser,
    storageKeys: [storageKey],
    blockNumber: l2BlockNumber,
  })

  // Build the output root proof
  const outputRootProof = {
    version: '0x0000000000000000000000000000000000000000000000000000000000000000' as Hex,
    stateRoot: l2Block.stateRoot!,
    messagePasserStorageRoot: proof.storageHash,
    latestBlockhash: l2Block.hash!,
  }

  // Verify the output root matches
  const computedOutputRoot = keccak256(
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

  if (computedOutputRoot !== outputRoot) {
    throw new Error(`Output root mismatch: expected ${outputRoot}, got ${computedOutputRoot}`)
  }

  return {
    to,
    amount,
    nonce,
    proposalId,
    outputRootProof,
    withdrawalProof: proof.storageProof[0].proof,
    bridgeAddress,
  }
}