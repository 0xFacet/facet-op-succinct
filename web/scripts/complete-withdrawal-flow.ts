import { 
  createPublicClient, 
  createWalletClient, 
  http,
  type Address,
  type Hash,
  type Hex,
  parseEther,
  formatEther,
  encodeAbiParameters,
  keccak256
} from 'viem';
import { mainnet, optimism } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

/**
 * Complete OP-Succinct Withdrawal Flow Example
 * 
 * This example walks through the entire withdrawal process from L2 to L1:
 * 1. Initiate withdrawal on L2
 * 2. Wait for L2 state to be proposed on L1
 * 3. Wait for proposal to become canonical
 * 4. Prove the withdrawal on L1
 * 5. Finalize the withdrawal to receive funds
 */

// Configuration
const config = {
  privateKey: process.env.PRIVATE_KEY as `0x${string}` || '0x...',
  
  // L1 contract addresses (get these from your deployment)
  l1BridgeAddress: '0x...' as Address,
  rollupAddress: '0x...' as Address,
  
  // L2 contract addresses
  l2ToL1MessagePasserAddress: '0x4200000000000000000000000000000000000016' as Address,
  
  // RPC endpoints
  l1RpcUrl: process.env.L1_RPC_URL || 'https://eth-mainnet.g.alchemy.com/v2/your-api-key',
  l2RpcUrl: process.env.L2_RPC_URL || 'https://opt-mainnet.g.alchemy.com/v2/your-api-key',
  
  // Withdrawal delay in seconds (must match contract)
  withdrawalDelaySecs: 24 * 60 * 60, // 24 hours
};

// Contract ABIs
const L2_BRIDGE_ABI = [
  {
    inputs: [
      { name: 'to', type: 'address' },
      { name: 'amount', type: 'uint256' }
    ],
    name: 'initiateWithdrawal',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function'
  },
  {
    inputs: [{ name: 'account', type: 'address' }],
    name: 'balanceOf',
    outputs: [{ name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function'
  }
] as const;

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
    name: 'finalizeWithdrawal',
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
    name: 'finalized',
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

// Helper to calculate withdrawal hash (matching L1Bridge._hashWithdrawal)
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

// Helper to hash output root proof (matching Hashing.hashOutputRootProof)
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
  console.log('🚀 OP-Succinct Complete Withdrawal Flow');
  console.log('======================================\n');

  // Setup clients
  const account = privateKeyToAccount(config.privateKey);
  
  const l1Client = createPublicClient({
    chain: mainnet,
    transport: http(config.l1RpcUrl)
  });

  const l1WalletClient = createWalletClient({
    account,
    chain: mainnet,
    transport: http(config.l1RpcUrl)
  });

  const l2Client = createPublicClient({
    chain: optimism,
    transport: http(config.l2RpcUrl)
  });

  const l2WalletClient = createWalletClient({
    account,
    chain: optimism,
    transport: http(config.l2RpcUrl)
  });

  // Get L2 bridge address from L1 bridge
  const l2BridgeAddress = await l1Client.readContract({
    address: config.l1BridgeAddress,
    abi: L1_BRIDGE_ABI,
    functionName: 'l2Bridge'
  });

  console.log(`L2 Bridge Address: ${l2BridgeAddress}`);

  // Withdrawal parameters
  const withdrawalAmount = parseEther('0.1');
  const recipient = account.address;

  console.log(`Withdrawal Amount: ${formatEther(withdrawalAmount)} ETH`);
  console.log(`Recipient: ${recipient}\n`);

  // ======================================
  // STEP 1: Initiate Withdrawal on L2
  // ======================================
  console.log('📤 STEP 1: Initiating withdrawal on L2...\n');

  // Check L2 balance
  const l2Balance = await l2Client.readContract({
    address: l2BridgeAddress,
    abi: L2_BRIDGE_ABI,
    functionName: 'balanceOf',
    args: [account.address]
  });

  console.log(`L2 Balance: ${formatEther(l2Balance)} ETH`);

  if (l2Balance < withdrawalAmount) {
    console.error('❌ Insufficient L2 balance for withdrawal');
    return;
  }

  // Initiate withdrawal
  console.log('Sending withdrawal transaction...');
  const withdrawTxHash = await l2WalletClient.writeContract({
    address: l2BridgeAddress,
    abi: L2_BRIDGE_ABI,
    functionName: 'initiateWithdrawal',
    args: [recipient, withdrawalAmount]
  });

  console.log(`Transaction hash: ${withdrawTxHash}`);
  console.log('Waiting for confirmation...');

  const withdrawReceipt = await l2Client.waitForTransactionReceipt({ 
    hash: withdrawTxHash 
  });

  // Get the actual nonce after the withdrawal
  // The nonce increments after initiateWithdrawal, so we subtract 1
  const currentNonce = await l2Client.readContract({
    address: config.l2ToL1MessagePasserAddress,
    abi: [{
      inputs: [],
      name: 'messageNonce',
      outputs: [{ name: '', type: 'uint256' }],
      stateMutability: 'view',
      type: 'function'
    }] as const,
    functionName: 'messageNonce'
  });
  
  const withdrawalNonce = currentNonce - 1n;
  
  // NOTE: In production, parse the WithdrawalInitiated event from the receipt
  // to get the exact nonce used

  console.log(`✅ Withdrawal initiated in block ${withdrawReceipt.blockNumber}`);
  console.log(`Withdrawal nonce: ${withdrawalNonce}\n`);

  // Get L2 block info for later
  const l2Block = await l2Client.getBlock({ 
    blockNumber: withdrawReceipt.blockNumber 
  });

  // Check if stateRoot is available
  if (!l2Block.stateRoot) {
    console.error('❌ stateRoot missing from L2 block - use a full node RPC endpoint');
    console.error('Public RPCs often omit this field. Try using a node provider with debug/full access.');
    return;
  }

  // ======================================
  // STEP 2: Wait for L2 State Proposal
  // ======================================
  console.log('⏳ STEP 2: Waiting for L2 state to be proposed on L1...\n');
  
  // NOTE: In production, you would:
  // 1. Monitor the Rollup contract for ProposalCreated events
  // 2. Wait for a proposal that includes your L2 block
  // 3. This typically happens every ~hour depending on configuration
  
  console.log('// In production: Monitor Rollup contract for proposals');
  console.log(`// Wait for proposal containing L2 block ${withdrawReceipt.blockNumber}`);
  console.log('// This may take 1-2 hours depending on proposer configuration\n');

  // For this example, we'll assume a proposal exists
  let proposalId: bigint | undefined;
  let outputRoot: Hash | undefined;

  // ======================================
  // STEP 3: Find Canonical Proposal
  // ======================================
  console.log('🔍 STEP 3: Finding canonical proposal...\n');

  // Get the output root proof components
  // NOTE: In production, use viem's getProof or an indexer
  const withdrawalHash = calculateWithdrawalHash(
    recipient,
    withdrawalAmount,
    withdrawalNonce,
    l2BridgeAddress,
    config.l1BridgeAddress
  );
  
  const storageKey = keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'uint256' }],
      [withdrawalHash, 0n]
    )
  );
  
  const l2StorageProof = await l2Client.getProof({
    address: config.l2ToL1MessagePasserAddress,
    storageKeys: [storageKey],
    blockNumber: withdrawReceipt.blockNumber
  });

  // Check if proof exists
  const proofArray = l2StorageProof.storageProof[0]?.proof;
  if (!proofArray || proofArray.length === 0) {
    console.error('❌ Withdrawal slot not yet in state - wait for batch to post');
    console.error('The L2 state might not have been submitted to L1 yet.');
    return;
  }

  const outputRootProof = {
    version: '0x0000000000000000000000000000000000000000000000000000000000000000' as Hash,
    stateRoot: l2Block.stateRoot!,
    messagePasserStorageRoot: l2StorageProof.storageHash,
    latestBlockhash: l2Block.hash!
  };

  const expectedOutputRoot = hashOutputRootProof(outputRootProof);
  console.log(`Expected output root: ${expectedOutputRoot}`);

  // Search for canonical proposal with this output root
  const proposalCount = await l1Client.readContract({
    address: config.rollupAddress,
    abi: ROLLUP_ABI,
    functionName: 'getProposalsLength'
  });

  console.log(`Searching through ${proposalCount} proposals...`);

  for (let i = 0n; i < proposalCount; i++) {
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
        outputRoot = proposal.rootClaim;
        console.log(`✅ Found canonical proposal: ${proposalId}`);
        console.log(`L2 Block: ${proposal.l2BlockNumber}\n`);
        break;
      }
    }
  }

  if (!proposalId) {
    console.log('❌ No canonical proposal found');
    console.log('// In production: Wait for proposer to submit and proposal to become canonical');
    console.log('// Proposals become canonical after challenge period (~1 week) or validity proof\n');
    return;
  }

  // ======================================
  // STEP 4: Prove Withdrawal on L1
  // ======================================
  console.log('🔐 STEP 4: Proving withdrawal on L1...\n');

  // withdrawalHash already calculated above, reuse it

  const provenInfo = await l1Client.readContract({
    address: config.l1BridgeAddress,
    abi: L1_BRIDGE_ABI,
    functionName: 'proven',
    args: [withdrawalHash]
  });

  if (provenInfo[1] > 0) {
    console.log('✅ Withdrawal already proven');
    console.log(`Proposal ID: ${provenInfo[0]}`);
    console.log(`Proven at: ${new Date(Number(provenInfo[1]) * 1000).toISOString()}\n`);
  } else {
    // Prove the withdrawal
    console.log('Submitting withdrawal proof...');
    
    const proveTxHash = await l1WalletClient.writeContract({
      address: config.l1BridgeAddress,
      abi: L1_BRIDGE_ABI,
      functionName: 'proveWithdrawal',
      args: [
        recipient,
        withdrawalAmount,
        withdrawalNonce,
        proposalId,
        outputRootProof,
        proofArray
      ]
    });

    console.log(`Transaction hash: ${proveTxHash}`);
    console.log('Waiting for confirmation...');

    const proveReceipt = await l1Client.waitForTransactionReceipt({ 
      hash: proveTxHash 
    });

    console.log(`✅ Withdrawal proven in block ${proveReceipt.blockNumber}`);
    console.log(`Gas used: ${proveReceipt.gasUsed}\n`);
  }

  // ======================================
  // STEP 5: Finalize Withdrawal
  // ======================================
  console.log('💰 STEP 5: Finalizing withdrawal...\n');

  // Check if already finalized
  const isFinalized = await l1Client.readContract({
    address: config.l1BridgeAddress,
    abi: L1_BRIDGE_ABI,
    functionName: 'finalized',
    args: [withdrawalHash]
  });

  if (isFinalized) {
    console.log('✅ Withdrawal already finalized');
    return;
  }

  // Check withdrawal delay
  const finalProvenInfo = await l1Client.readContract({
    address: config.l1BridgeAddress,
    abi: L1_BRIDGE_ABI,
    functionName: 'proven',
    args: [withdrawalHash]
  });

  const provenAt = Number(finalProvenInfo[1]);
  const readyAt = provenAt + config.withdrawalDelaySecs;
  const now = Math.floor(Date.now() / 1000);

  if (now < readyAt) {
    const waitTime = readyAt - now;
    console.log(`⏳ Withdrawal delay active. Must wait ${waitTime} seconds (${Math.floor(waitTime / 60)} minutes)`);
    console.log(`Ready at: ${new Date(readyAt * 1000).toISOString()}`);
    console.log('Waiting...');
    
    // Wait for the delay period plus 5 seconds buffer
    await new Promise(resolve => setTimeout(resolve, (waitTime + 5) * 1000));
  }

  // Get initial balance
  const initialBalance = await l1Client.getBalance({ 
    address: recipient 
  });

  // Finalize the withdrawal
  console.log('Finalizing withdrawal...');
  
  const finalizeTxHash = await l1WalletClient.writeContract({
    address: config.l1BridgeAddress,
    abi: L1_BRIDGE_ABI,
    functionName: 'finalizeWithdrawal',
    args: [recipient, withdrawalAmount, withdrawalNonce]
  });

  console.log(`Transaction hash: ${finalizeTxHash}`);
  console.log('Waiting for confirmation...');

  const finalizeReceipt = await l1Client.waitForTransactionReceipt({ 
    hash: finalizeTxHash 
  });

  // Get final balance
  const finalBalance = await l1Client.getBalance({ 
    address: recipient 
  });

  // Calculate net received (subtract gas cost)
  const gasCost = finalizeReceipt.gasUsed * finalizeReceipt.effectiveGasPrice;
  const netReceived = finalBalance - initialBalance;
  const grossReceived = netReceived + gasCost;

  console.log(`✅ Withdrawal finalized in block ${finalizeReceipt.blockNumber}`);
  console.log(`Gas used: ${finalizeReceipt.gasUsed}`);
  console.log(`Gas cost: ${formatEther(gasCost)} ETH`);
  console.log(`Gross received: ${formatEther(grossReceived)} ETH`);
  console.log(`Net received: ${formatEther(netReceived)} ETH`);
  console.log('\n🎉 Withdrawal complete!');

  // ======================================
  // Summary
  // ======================================
  console.log('\n📊 Withdrawal Summary:');
  console.log('====================');
  console.log(`Amount: ${formatEther(withdrawalAmount)} ETH`);
  console.log(`Recipient: ${recipient}`);
  console.log(`Withdrawal Hash: ${withdrawalHash}`);
  console.log(`L2 Block: ${withdrawReceipt.blockNumber}`);
  console.log(`Proposal ID: ${proposalId}`);
  console.log(`Total time: ~1-2 hours (with fast finality) or ~1 week (optimistic)`);
}

// Run the example
main().catch((error) => {
  console.error('❌ Error:', error);
  process.exit(1);
});