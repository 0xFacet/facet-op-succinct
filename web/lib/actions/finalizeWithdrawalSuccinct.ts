import type { Address, Chain, Client, Transport, Account, Hex } from 'viem'
import { writeContract } from 'viem/actions'

const l1EthBridgeAbi = [
  {
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'nonce', type: 'uint256' },
    ],
    name: 'finaliseWithdrawal',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
] as const

export interface FinalizeWithdrawalSuccinctParameters {
  /** Address of the recipient of the withdrawal. */
  to: Address
  /** Amount to withdraw. */
  amount: bigint
  /** Nonce of the withdrawal. */
  nonce: bigint
  /** Address of the L1 ETH bridge contract. */
  bridgeAddress: Address
}

export type FinalizeWithdrawalSuccinctReturnType = Hex

/**
 * Finalizes a withdrawal on an OP-Succinct L1 ETH Bridge.
 */
export async function finalizeWithdrawalSuccinct(
  client: Client<Transport, Chain, Account>,
  parameters: FinalizeWithdrawalSuccinctParameters,
): Promise<FinalizeWithdrawalSuccinctReturnType> {
  const {
    to,
    amount,
    nonce,
    bridgeAddress,
  } = parameters

  return writeContract(client, {
    address: bridgeAddress,
    abi: l1EthBridgeAbi,
    functionName: 'finaliseWithdrawal',
    args: [to, amount, nonce],
  })
}