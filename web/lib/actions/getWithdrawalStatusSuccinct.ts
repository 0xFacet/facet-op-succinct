import type { Address, Chain, Client, Hex, Transport, StateOverride } from 'viem'
import { readContract } from 'viem/actions'
import { keccak256, encodeAbiParameters } from 'viem'

const l1EthBridgeAbi = [
  {
    inputs: [{ name: 'withdrawalHash', type: 'bytes32' }],
    name: 'proven',
    outputs: [
      { name: 'proposalId', type: 'uint32' },
      { name: 'provenAt', type: 'uint32' },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [{ name: 'withdrawalHash', type: 'bytes32' }],
    name: 'finalised',
    outputs: [{ type: 'bool' }],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'l2Bridge',
    outputs: [{ type: 'address' }],
    stateMutability: 'view',
    type: 'function',
  },
] as const

export interface WithdrawalStatusSuccinctParameters {
  /** Recipient address on L1 */
  to: Address
  /** Amount to withdraw */
  amount: bigint
  /** Withdrawal nonce */
  nonce: bigint
  /** Address of the L1 ETH bridge contract */
  bridgeAddress: Address
  /** State overrides for simulation */
  stateOverride?: StateOverride | undefined
}

export interface WithdrawalStatusSuccinctReturnType {
  /** The withdrawal hash */
  withdrawalHash: Hex
  /** The storage key in L2ToL1MessagePasser */
  storageKey: Hex
  /** Whether the withdrawal has been proven */
  isProven: boolean
  /** Whether the withdrawal has been finalized */
  isFinalized: boolean
  /** Whether the withdrawal can be finalized (proven but not yet finalized and past delay) */
  canFinalize: boolean
  /** Proof details if proven */
  provenWithdrawal?: {
    proposalId: number
    provenAt: number
  }
}

/**
 * Gets the complete status of a withdrawal on the OP-Succinct L1 ETH Bridge.
 *
 * @param client - Client to use
 * @param parameters - {@link WithdrawalStatusSuccinctParameters}
 * @returns Withdrawal status and details. {@link WithdrawalStatusSuccinctReturnType}
 *
 * @example
 * import { createPublicClient, http } from 'viem'
 * import { mainnet } from 'viem/chains'
 * import { getWithdrawalStatusSuccinct } from 'viem/op-stack'
 *
 * const client = createPublicClient({
 *   chain: mainnet,
 *   transport: http(),
 * })
 *
 * const status = await getWithdrawalStatusSuccinct(client, {
 *   to: '0x...',
 *   amount: 1000000000000000000n,
 *   nonce: 1n,
 *   bridgeAddress: '0x...',
 * })
 */
export async function getWithdrawalStatusSuccinct<chain extends Chain | undefined>(
  client: Client<Transport, chain>,
  parameters: WithdrawalStatusSuccinctParameters,
): Promise<WithdrawalStatusSuccinctReturnType> {
  const { to, amount, nonce, bridgeAddress, stateOverride } = parameters

  // Get L2 bridge address
  const l2Bridge = await readContract(client, {
    address: bridgeAddress,
    abi: l1EthBridgeAbi,
    functionName: 'l2Bridge',
    stateOverride,
  })

  // Calculate withdrawal hash
  const data = encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }],
    [to, amount]
  )

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

  // Calculate storage key
  const storageKey = keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'uint256' }],
      [withdrawalHash, 0n]
    )
  )

  // Check if proven
  const [proposalId, provenAt] = await readContract(client, {
    address: bridgeAddress,
    abi: l1EthBridgeAbi,
    functionName: 'proven',
    args: [withdrawalHash],
    stateOverride,
  })

  // Check if finalized
  const isFinalized = await readContract(client, {
    address: bridgeAddress,
    abi: l1EthBridgeAbi,
    functionName: 'finalised',
    args: [withdrawalHash],
    stateOverride,
  })

  const isProven = provenAt > 0
  const currentTime = Math.floor(Date.now() / 1000)
  const withdrawalDelay = 60 // Default 60 seconds, should be passed as parameter in production
  const canFinalize = isProven && !isFinalized && currentTime > provenAt + withdrawalDelay

  return {
    withdrawalHash,
    storageKey,
    isProven,
    isFinalized,
    canFinalize,
    provenWithdrawal: isProven ? { proposalId: Number(proposalId), provenAt: Number(provenAt) } : undefined,
  }
}