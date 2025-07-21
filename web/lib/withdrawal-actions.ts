import { 
  type Address,
  type Hash,
  type Hex,
  keccak256,
  encodeAbiParameters,
  parseAbiParameters,
  decodeAbiParameters,
  decodeEventLog
} from 'viem'
import { l1PublicClient, l2PublicClient, config } from './config'
import { ROLLUP_ABI, L1_ETH_BRIDGE_ABI, L2_TO_L1_MESSAGE_PASSER_ABI, L2_TO_L1_MESSAGE_PASSER_ADDRESS } from './contracts'
import type { OutputRootProof } from './actions/types'

export interface WithdrawalData {
  to: Address
  amount: bigint
  nonce: bigint
  withdrawalHash: Hash
}

// Get withdrawal data from transaction hash
export async function getWithdrawalDataFromTx(txHash: Hash): Promise<WithdrawalData> {
  const receipt = await l2PublicClient.getTransactionReceipt({ hash: txHash })
  
  // Find the MessagePassed event log
  const messagePassedEvent = {
    type: 'event' as const,
    name: 'MessagePassed',
    inputs: L2_TO_L1_MESSAGE_PASSER_ABI.find(abi => abi.name === 'MessagePassed')!.inputs
  }
  
  const logs = receipt.logs.filter(log => 
    log.address.toLowerCase() === L2_TO_L1_MESSAGE_PASSER_ADDRESS.toLowerCase()
  )
  
  if (logs.length === 0) {
    throw new Error('No withdrawal found in transaction')
  }
  
  // Decode the MessagePassed event
  let eventData: {
    eventName: 'MessagePassed'
    args: {
      nonce: bigint
      sender: Address
      target: Address
      value: bigint
      gasLimit: bigint
      data: Hex
      withdrawalHash: Hash
    }
  } | null = null
  
  for (const log of logs) {
    try {
      const decoded = decodeEventLog({
        abi: [messagePassedEvent],
        data: log.data,
        topics: log.topics
      })
      eventData = decoded as any
      break
    } catch {
      // Continue to next log
    }
  }
  
  if (!eventData) {
    throw new Error('Failed to decode MessagePassed event')
  }
  
  // Extract data from the event - no need to calculate nonce!
  const nonce = eventData.args.nonce
  const withdrawalHash = eventData.args.withdrawalHash
  const data = eventData.args.data
  
  // Decode the withdrawal data to get recipient and amount
  const [to, amount] = decodeAbiParameters(
    parseAbiParameters('address, uint256'),
    data
  )

  return { to, amount, nonce, withdrawalHash }
}

// Hash withdrawal according to OP Stack spec
function hashWithdrawal(withdrawal: {
  nonce: bigint
  sender: Address
  target: Address
  value: bigint
  gasLimit: bigint
  data: Hex
}): Hash {
  const encoded = encodeAbiParameters(
    parseAbiParameters('uint256, address, address, uint256, uint256, bytes'),
    [
      withdrawal.nonce,
      withdrawal.sender,
      withdrawal.target,
      withdrawal.value,
      withdrawal.gasLimit,
      withdrawal.data
    ]
  )
  return keccak256(encoded)
}

// Compute withdrawal hash with clearer parameter names
export function computeWithdrawalHash(params: {
  nonce: bigint
  l2Bridge: Address
  l1Bridge: Address
  to: Address
  amount: bigint
}): Hash {
  const data = encodeAbiParameters(
    parseAbiParameters('address, uint256'),
    [params.to, params.amount]
  )
  
  return hashWithdrawal({
    nonce: params.nonce,
    sender: params.l2Bridge,
    target: params.l1Bridge,
    value: 0n,
    gasLimit: 0n,
    data
  })
}

// Find canonical proposal for a given output root
export async function findCanonicalProposal(
  outputRootProof: OutputRootProof
): Promise<number | null> {
  const targetRoot = hashOutputRootProof(outputRootProof)
  const proposalCount = await l1PublicClient.readContract({
    address: config.rollupAddress,
    abi: ROLLUP_ABI,
    functionName: 'getProposalsLength'
  })

  // Search through proposals
  for (let i = 0; i < proposalCount; i++) {
    const [proposal, isCanonical] = await Promise.all([
      l1PublicClient.readContract({
        address: config.rollupAddress,
        abi: ROLLUP_ABI,
        functionName: 'getProposal',
        args: [BigInt(i)]
      }),
      l1PublicClient.readContract({
        address: config.rollupAddress,
        abi: ROLLUP_ABI,
        functionName: 'proposalIsCanonical',
        args: [BigInt(i)]
      })
    ])

    if (isCanonical && proposal.rootClaim === targetRoot) {
      return i
    }
  }

  return null
}

// Hash output root proof
function hashOutputRootProof(proof: OutputRootProof): Hash {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters('bytes32, bytes32, bytes32, bytes32'),
      [proof.version, proof.stateRoot, proof.messagePasserStorageRoot, proof.latestBlockhash]
    )
  )
}

// Get withdrawal status
export async function getWithdrawalStatus(withdrawalHash: Hash) {
  const [provenInfo, isFinalized] = await Promise.all([
    l1PublicClient.readContract({
      address: config.l1ETHBridgeAddress,
      abi: L1_ETH_BRIDGE_ABI,
      functionName: 'proven',
      args: [withdrawalHash]
    }),
    l1PublicClient.readContract({
      address: config.l1ETHBridgeAddress,
      abi: L1_ETH_BRIDGE_ABI,
      functionName: 'finalised',
      args: [withdrawalHash]
    })
  ])

  const isProven = provenInfo[1] > 0
  const provenAt = isProven ? Number(provenInfo[1]) : null
  const proposalId = isProven ? Number(provenInfo[0]) : null

  return {
    isProven,
    isFinalized,
    provenAt,
    proposalId,
    canFinalize: isProven && !isFinalized && provenAt !== null && 
      Date.now() / 1000 > provenAt + config.withdrawalDelaySecs
  }
}