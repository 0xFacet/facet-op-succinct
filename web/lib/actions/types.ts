import type { Address, Hex } from 'viem'

export type OutputRootProof = {
  version: Hex
  stateRoot: Hex
  messagePasserStorageRoot: Hex
  latestBlockhash: Hex
}

export type Withdrawal = {
  nonce: bigint
  sender: Address
  target: Address
  value: bigint
  gasLimit: bigint
  data: Hex
}

export type Proposal = {
  rootClaim: Hex
  proposer: Address
  l2BlockNumber: number
  parentIndex: number
  deadline: number
  resolvedAt: bigint
  proposalStatus: number
  resolutionStatus: number
  challenger: Address
  prover: Address
}