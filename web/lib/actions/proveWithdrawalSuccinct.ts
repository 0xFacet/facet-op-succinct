import type { Address, Chain, Client, Hex, Transport, Account } from 'viem'
import { writeContract } from 'viem/actions'
import type { OutputRootProof } from './types'

const l1EthBridgeAbi = [
  {
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'nonce', type: 'uint256' },
      { name: 'proposalId', type: 'uint256' },
      {
        name: 'rootProof',
        type: 'tuple',
        components: [
          { name: 'version', type: 'bytes32' },
          { name: 'stateRoot', type: 'bytes32' },
          { name: 'messagePasserStorageRoot', type: 'bytes32' },
          { name: 'latestBlockhash', type: 'bytes32' },
        ],
      },
      { name: 'withdrawalProof', type: 'bytes[]' },
    ],
    name: 'proveWithdrawal',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
] as const

export interface ProveWithdrawalSuccinctParameters {
  /** Address of the recipient of the withdrawal. */
  to: Address
  /** Amount to withdraw. */
  amount: bigint
  /** Nonce of the withdrawal. */
  nonce: bigint
  /** ID of the canonical proposal from the Rollup contract. */
  proposalId: bigint
  /** Root proof containing state roots. */
  outputRootProof: OutputRootProof
  /** Array of hex strings that prove the withdrawal was included in the L2 state. */
  withdrawalProof: readonly Hex[]
  /** Address of the L1 ETH bridge contract. */
  bridgeAddress: Address
}

export type ProveWithdrawalSuccinctReturnType = Hex

/**
 * Proves a withdrawal on an OP-Succinct L1 ETH Bridge.
 */
export async function proveWithdrawalSuccinct(
  client: Client<Transport, Chain, Account>,
  parameters: ProveWithdrawalSuccinctParameters,
): Promise<ProveWithdrawalSuccinctReturnType> {
  const {
    to,
    amount,
    nonce,
    proposalId,
    outputRootProof,
    withdrawalProof,
    bridgeAddress,
  } = parameters

  return writeContract(client, {
    address: bridgeAddress,
    abi: l1EthBridgeAbi,
    functionName: 'proveWithdrawal',
    args: [to, amount, nonce, proposalId, outputRootProof, withdrawalProof],
  })
}