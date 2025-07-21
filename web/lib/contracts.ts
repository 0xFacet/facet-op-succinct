import type { Abi } from 'viem'

export const ROLLUP_ABI = [
  {
    inputs: [],
    name: 'PROPOSAL_INTERVAL',
    outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ internalType: 'uint256', name: 'id', type: 'uint256' }],
    name: 'getProposal',
    outputs: [
      {
        components: [
          { internalType: 'bytes32', name: 'rootClaim', type: 'bytes32' },
          { internalType: 'address', name: 'proposer', type: 'address' },
          { internalType: 'uint32', name: 'l2BlockNumber', type: 'uint32' },
          { internalType: 'uint32', name: 'parentIndex', type: 'uint32' },
          { internalType: 'uint32', name: 'deadline', type: 'uint32' },
          { internalType: 'uint64', name: 'resolvedAt', type: 'uint64' },
          { internalType: 'uint8', name: 'proposalStatus', type: 'uint8' },
          { internalType: 'uint8', name: 'resolutionStatus', type: 'uint8' },
          { internalType: 'address', name: 'challenger', type: 'address' },
          { internalType: 'address', name: 'prover', type: 'address' }
        ],
        internalType: 'struct Rollup.Proposal',
        name: '',
        type: 'tuple'
      }
    ],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [],
    name: 'getProposalsLength',
    outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ internalType: 'uint256', name: 'proposalId', type: 'uint256' }],
    name: 'proposalIsCanonical',
    outputs: [{ internalType: 'bool', name: '', type: 'bool' }],
    stateMutability: 'view',
    type: 'function'
  }
] as const satisfies Abi

export const L1_ETH_BRIDGE_ABI = [
  {
    inputs: [
      { internalType: 'address', name: 'to', type: 'address' },
      { internalType: 'uint256', name: 'amount', type: 'uint256' },
      { internalType: 'uint256', name: 'nonce', type: 'uint256' },
      { internalType: 'uint256', name: 'proposalId', type: 'uint256' },
      {
        components: [
          { internalType: 'bytes32', name: 'version', type: 'bytes32' },
          { internalType: 'bytes32', name: 'stateRoot', type: 'bytes32' },
          { internalType: 'bytes32', name: 'messagePasserStorageRoot', type: 'bytes32' },
          { internalType: 'bytes32', name: 'latestBlockhash', type: 'bytes32' }
        ],
        internalType: 'struct Types.OutputRootProof',
        name: 'rootProof',
        type: 'tuple'
      },
      { internalType: 'bytes[]', name: 'withdrawalProof', type: 'bytes[]' }
    ],
    name: 'proveWithdrawal',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function'
  },
  {
    inputs: [
      { internalType: 'address', name: 'to', type: 'address' },
      { internalType: 'uint256', name: 'amount', type: 'uint256' },
      { internalType: 'uint256', name: 'nonce', type: 'uint256' }
    ],
    name: 'finalizeWithdrawal',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function'
  },
  {
    inputs: [
      { internalType: 'bytes32', name: '', type: 'bytes32' },
      { internalType: 'address', name: '', type: 'address' }
    ],
    name: 'proven',
    outputs: [
      { internalType: 'uint32', name: 'proposalId', type: 'uint32' },
      { internalType: 'uint32', name: 'provenAt', type: 'uint32' }
    ],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ internalType: 'bytes32', name: '', type: 'bytes32' }],
    name: 'finalized',
    outputs: [{ internalType: 'bool', name: '', type: 'bool' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [],
    name: 'l2Bridge',
    outputs: [{ internalType: 'address', name: '', type: 'address' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    name: 'WithdrawalProven',
    type: 'event',
    inputs: [
      { indexed: true, name: 'rollup', type: 'address' },
      { indexed: true, name: 'to', type: 'address' },
      { indexed: false, name: 'amount', type: 'uint256' },
      { indexed: false, name: 'nonce', type: 'uint256' },
      { indexed: false, name: 'proposalId', type: 'uint256' }
    ]
  },
  {
    name: 'WithdrawalFinalized',
    type: 'event',
    inputs: [
      { indexed: true, name: 'to', type: 'address' },
      { indexed: false, name: 'amount', type: 'uint256' },
      { indexed: false, name: 'nonce', type: 'uint256' }
    ]
  }
] as const satisfies Abi

export const L2_TO_L1_MESSAGE_PASSER_ABI = [
  {
    inputs: [],
    name: 'messageNonce',
    outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    name: 'MessagePassed',
    type: 'event',
    inputs: [
      { indexed: true, name: 'nonce', type: 'uint256' },
      { indexed: true, name: 'sender', type: 'address' },
      { indexed: true, name: 'target', type: 'address' },
      { indexed: false, name: 'value', type: 'uint256' },
      { indexed: false, name: 'gasLimit', type: 'uint256' },
      { indexed: false, name: 'data', type: 'bytes' },
      { indexed: false, name: 'withdrawalHash', type: 'bytes32' }
    ]
  }
] as const satisfies Abi

// Standard L2ToL1MessagePasser address
export const L2_TO_L1_MESSAGE_PASSER_ADDRESS = '0x4200000000000000000000000000000000000016' as const