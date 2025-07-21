import { 
  createPublicClient, 
  createWalletClient, 
  http,
  type Address,
  type Hash,
  parseEther,
  formatEther,
  encodeAbiParameters,
  keccak256
} from 'viem';
import { sepolia } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import * as dotenv from 'dotenv';
import * as path from 'path';

// Load .env.sepolia
dotenv.config({ path: path.join(process.cwd(), '.env.sepolia') });

/**
 * End-to-end script for proving and finalizing withdrawals on Sepolia
 * This script:
 * 1. Reads configuration from .env.sepolia
 * 2. Assumes withdrawal has already been initiated on L2
 * 3. Finds the canonical proposal
 * 4. Proves the withdrawal
 * 5. Finalizes after the delay period
 */

// Contract ABIs
const L1_BRIDGE_ABI = [
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
          { name: 'latestBlockhash', type: 'bytes32' }
        ]
      },
      { name: 'withdrawalProof', type: 'bytes[]' }
    ],
    name: 'proveWithdrawal',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function'
  },
  {
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'nonce', type: 'uint256' }
    ],
    name: 'finaliseWithdrawal',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function'
  },
  {
    inputs: [{ name: 'withdrawalHash', type: 'bytes32' }],
    name: 'proven',
    outputs: [
      { name: 'proposalId', type: 'uint32' },
      { name: 'provenAt', type: 'uint32' }
    ],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ name: 'withdrawalHash', type: 'bytes32' }],
    name: 'finalised',
    outputs: [{ name: '', type: 'bool' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [],
    name: 'l2Bridge',
    outputs: [{ name: '', type: 'address' }],
    stateMutability: 'view',
    type: 'function'
  }
] as const;

const ROLLUP_ABI = [
  {
    inputs: [{ name: 'id', type: 'uint256' }],
    name: 'getProposal',
    outputs: [{
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
        { name: 'prover', type: 'address' }
      ],
      type: 'tuple'
    }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [{ name: 'proposalId', type: 'uint256' }],
    name: 'proposalIsCanonical',
    outputs: [{ name: '', type: 'bool' }],
    stateMutability: 'view',
    type: 'function'
  },
  {
    inputs: [],
    name: 'getProposalsLength',
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function'
  }
] as const;

// Configuration from .env.sepolia
const config = {
  // Private key and RPC from .env.sepolia
  privateKey: process.env.PRIVATE_KEY as `0x${string}`,
  l1RpcUrl: process.env.L1_RPC_URL!,
  l2RpcUrl: process.env.L2_RPC_URL!,
  
  // Contract addresses - these should be set after deployment
  l1ETHBridgeAddress: "0x4A7Db6a4ACe349d69BB72E73ABe2712a76E15428" as Address,
  rollupAddress: "0xb3e0406017407baEd43652C440b304B858432B98" as Address,
  
  // L2 constants
  l2ToL1MessagePasserAddress: '0x4200000000000000000000000000000000000016' as Address,
  
  // Testing configuration - short delays
  withdrawalDelaySecs: 60, // 1 minute for testing
};

// Helper functions
function calculateWithdrawalHash(
  to: Address,
  amount: bigint,
  nonce: bigint,
  l2BridgeAddress: Address,
  l1BridgeAddress: Address
): Hash {
  const data = encodeAbiParameters(
    [{ type: 'address' }, { type: 'uint256' }],
    [to, amount]
  );
  
  const withdrawalStruct = encodeAbiParameters(
    [
      { type: 'uint256' }, // nonce
      { type: 'address' }, // sender (L2 bridge)
      { type: 'address' }, // target (L1 bridge)
      { type: 'uint256' }, // value (0 for ETH)
      { type: 'uint256' }, // gasLimit (0)
      { type: 'bytes' }    // data
    ],
    [nonce, l2BridgeAddress, l1BridgeAddress, 0n, 0n, data]
  );
  
  return keccak256(withdrawalStruct);
}

function hashOutputRootProof(proof: {
  version: Hash;
  stateRoot: Hash;
  messagePasserStorageRoot: Hash;
  latestBlockhash: Hash;
}): Hash {
  return keccak256(
    encodeAbiParameters(
      [
        { type: 'bytes32' },
        { type: 'bytes32' },
        { type: 'bytes32' },
        { type: 'bytes32' }
      ],
      [
        proof.version,
        proof.stateRoot,
        proof.messagePasserStorageRoot,
        proof.latestBlockhash
      ]
    )
  );
}

async function main() {
  console.log('🚀 OP-Succinct Withdrawal Proof & Finalize (Sepolia)');
  console.log('===================================================\n');

  // Validate configuration
  if (!config.privateKey || config.privateKey === '0x...') {
    console.error('❌ PRIVATE_KEY not set in .env.sepolia');
    process.exit(1);
  }

  if (!config.l1RpcUrl || !config.l2RpcUrl) {
    console.error('❌ RPC URLs not set in .env.sepolia');
    process.exit(1);
  }

  if (config.l1ETHBridgeAddress === '0x...' || config.rollupAddress === '0x...') {
    console.error('❌ Contract addresses not set. Please deploy contracts first and update .env.sepolia');
    process.exit(1);
  }

  // Setup clients
  const account = privateKeyToAccount(config.privateKey);
  
  const l1Client = createPublicClient({
    chain: sepolia,
    transport: http(config.l1RpcUrl)
  });

  const l1WalletClient = createWalletClient({
    account,
    chain: sepolia,
    transport: http(config.l1RpcUrl)
  });

  const l2Client = createPublicClient({
    transport: http(config.l2RpcUrl)
  });

  // Get withdrawal parameters from command line or use defaults
  const withdrawalParams = {
    to: account.address,
    amount: parseEther(process.argv[2] || '0.001'), // Default 0.001 ETH
    nonce: BigInt(process.argv[3] || '0'), // Must provide the actual nonce from L2 withdrawal
    l2BlockNumber: BigInt(process.argv[4] || '0'), // Must provide the L2 block number
  };

  if (withdrawalParams.l2BlockNumber === 0n) {
    console.error('❌ Please provide L2 block number as third argument');
    console.error('Usage: pnpm ts-node prove-and-finalize-sepolia.ts <amount> <nonce> <l2BlockNumber>');
    process.exit(1);
  }

  console.log('Withdrawal Parameters:');
  console.log(`To: ${withdrawalParams.to}`);
  console.log(`Amount: ${formatEther(withdrawalParams.amount)} ETH`);
  console.log(`Nonce: ${withdrawalParams.nonce}`);
  console.log(`L2 Block: ${withdrawalParams.l2BlockNumber}\n`);

  // Get L2 bridge address
  const l2BridgeAddress = await l1Client.readContract({
    address: config.l1ETHBridgeAddress,
    abi: L1_BRIDGE_ABI,
    functionName: 'l2Bridge'
  });

  console.log(`L2 Bridge: ${l2BridgeAddress}\n`);

  // Calculate withdrawal hash
  const withdrawalHash = calculateWithdrawalHash(
    withdrawalParams.to,
    withdrawalParams.amount,
    withdrawalParams.nonce,
    l2BridgeAddress,
    config.l1ETHBridgeAddress
  );

  console.log(`Withdrawal Hash: ${withdrawalHash}\n`);

  // Check if already proven/finalized
  const provenInfo = await l1Client.readContract({
    address: config.l1ETHBridgeAddress,
    abi: L1_BRIDGE_ABI,
    functionName: 'proven',
    args: [withdrawalHash]
  });

  const isFinalized = await l1Client.readContract({
    address: config.l1ETHBridgeAddress,
    abi: L1_BRIDGE_ABI,
    functionName: 'finalised',
    args: [withdrawalHash]
  });

  if (isFinalized) {
    console.log('✅ Withdrawal already finalized!');
    return;
  }

  // Step 1: Prove withdrawal if not proven
  if (provenInfo[1] === 0) {
    console.log('📝 STEP 1: Proving withdrawal...\n');

    // Get L2 block data
    const l2Block = await l2Client.getBlock({ 
      blockNumber: withdrawalParams.l2BlockNumber 
    });

    if (!l2Block.stateRoot) {
      console.error('❌ L2 block missing stateRoot. Use a full node RPC.');
      process.exit(1);
    }

    // Get storage proof
    const storageKey = keccak256(
      encodeAbiParameters(
        [{ type: 'bytes32' }, { type: 'uint256' }],
        [withdrawalHash, 0n]
      )
    );

    const l2StorageProof = await l2Client.getProof({
      address: config.l2ToL1MessagePasserAddress,
      storageKeys: [storageKey],
      blockNumber: withdrawalParams.l2BlockNumber
    });

    const proofArray = l2StorageProof.storageProof[0]?.proof;
    if (!proofArray || proofArray.length === 0) {
      console.error('❌ Withdrawal not found in L2 state. Has the withdrawal been initiated?');
      process.exit(1);
    }

    // Build output root proof
    const outputRootProof = {
      version: '0x0000000000000000000000000000000000000000000000000000000000000000' as Hash,
      stateRoot: l2Block.stateRoot,
      messagePasserStorageRoot: l2StorageProof.storageHash,
      latestBlockhash: l2Block.hash!
    };

    const expectedOutputRoot = hashOutputRootProof(outputRootProof);
    console.log(`Expected output root: ${expectedOutputRoot}`);

    // Find canonical proposal
    console.log('Searching for canonical proposal...');
    const proposalCount = await l1Client.readContract({
      address: config.rollupAddress,
      abi: ROLLUP_ABI,
      functionName: 'getProposalsLength'
    });

    let proposalId: bigint | undefined;
    
    // Search backwards from most recent proposals
    for (let i = proposalCount - 1n; i >= 0n && i >= proposalCount - 100n; i--) {
      const proposal = await l1Client.readContract({
        address: config.rollupAddress,
        abi: ROLLUP_ABI,
        functionName: 'getProposal',
        args: [i]
      });

      if (proposal.rootClaim === expectedOutputRoot) {
        const isCanonical = await l1Client.readContract({
          address: config.rollupAddress,
          abi: ROLLUP_ABI,
          functionName: 'proposalIsCanonical',
          args: [i]
        });

        if (isCanonical) {
          proposalId = i;
          console.log(`✅ Found canonical proposal: ${proposalId}`);
          break;
        }
      }
    }

    if (proposalId === undefined) {
      console.error('❌ No canonical proposal found. Wait for the proposal to be submitted and become canonical.');
      process.exit(1);
    }

    // Submit proof
    console.log('\nSubmitting withdrawal proof...');
    const proveTx = await l1WalletClient.writeContract({
      address: config.l1ETHBridgeAddress,
      abi: L1_BRIDGE_ABI,
      functionName: 'proveWithdrawal',
      args: [
        withdrawalParams.to,
        withdrawalParams.amount,
        withdrawalParams.nonce,
        proposalId,
        outputRootProof,
        proofArray
      ]
    });

    console.log(`Transaction: ${proveTx}`);
    const proveReceipt = await l1Client.waitForTransactionReceipt({ hash: proveTx });
    console.log(`✅ Withdrawal proven in block ${proveReceipt.blockNumber}\n`);
  } else {
    console.log(`✅ Withdrawal already proven at ${new Date(Number(provenInfo[1]) * 1000).toISOString()}\n`);
  }

  // Step 2: Wait for delay and finalize
  console.log('💰 STEP 2: Finalizing withdrawal...\n');

  // Get latest proven info
  const latestProvenInfo = await l1Client.readContract({
    address: config.l1ETHBridgeAddress,
    abi: L1_BRIDGE_ABI,
    functionName: 'proven',
    args: [withdrawalHash]
  });

  const provenAt = Number(latestProvenInfo[1]);
  const readyAt = provenAt + config.withdrawalDelaySecs;
  const now = Math.floor(Date.now() / 1000);

  if (now < readyAt) {
    const waitTime = readyAt - now;
    console.log(`⏳ Must wait ${waitTime} seconds for withdrawal delay`);
    console.log(`Ready at: ${new Date(readyAt * 1000).toISOString()}`);
    console.log('Waiting...\n');
    
    await new Promise(resolve => setTimeout(resolve, (waitTime + 5) * 1000));
  }

  // Finalize
  const initialBalance = await l1Client.getBalance({ address: withdrawalParams.to });
  
  console.log('Submitting finalization transaction...');
  const finalizeTx = await l1WalletClient.writeContract({
    address: config.l1ETHBridgeAddress,
    abi: L1_BRIDGE_ABI,
    functionName: 'finaliseWithdrawal',
    args: [withdrawalParams.to, withdrawalParams.amount, withdrawalParams.nonce]
  });

  console.log(`Transaction: ${finalizeTx}`);
  const finalizeReceipt = await l1Client.waitForTransactionReceipt({ hash: finalizeTx });
  
  const finalBalance = await l1Client.getBalance({ address: withdrawalParams.to });
  const netReceived = finalBalance - initialBalance;

  console.log(`\n✅ Withdrawal finalized!`);
  console.log(`Block: ${finalizeReceipt.blockNumber}`);
  console.log(`Gas used: ${finalizeReceipt.gasUsed}`);
  console.log(`Net received: ${formatEther(netReceived)} ETH`);
}

// Run
main().catch((error) => {
  console.error('\n❌ Error:', error);
  process.exit(1);
});