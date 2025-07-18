import { 
  createPublicClient, 
  createWalletClient, 
  http,
  type Address,
  type Hash,
  formatEther,
  encodeAbiParameters,
  keccak256,
  decodeEventLog,
  parseAbiParameters
} from 'viem';
import { sepolia, optimismSepolia } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { loadSepoliaEnv } from '../lib/load-env';
import { 
  getWithdrawalStatusSuccinct,
  findCanonicalProposal,
  buildProveWithdrawalSuccinct,
  proveWithdrawalSuccinct,
  finalizeWithdrawalSuccinct,
  type OutputRootProof
} from '../lib/actions';

// Load environment
loadSepoliaEnv();

/**
 * Simplified script that takes just a withdrawal transaction hash
 * and handles everything else automatically
 * 
 * Usage: pnpm prove-from-tx <withdrawal-tx-hash>
 */

// Get tx hash from command line
const txHash = process.argv[2] as Hash;
if (!txHash) {
  console.error('Usage: pnpm prove-from-tx <withdrawal-tx-hash>');
  process.exit(1);
}

// Configuration from environment
const config = {
  privateKey: (process.env.PRIVATE_KEY || '0x') as `0x${string}`,
  l1RpcUrl: process.env.L1_RPC || 'https://eth-sepolia.g.alchemy.com/v2/demo',
  l2RpcUrl: process.env.L2_RPC || 'https://sepolia.optimism.io',
  l1ETHBridgeAddress: (process.env.L1_ETH_BRIDGE_ADDRESS || '0x4A7Db6a4ACe349d69BB72E73ABe2712a76E15428') as Address,
  rollupAddress: (process.env.ROLLUP_ADDRESS || '0xb3e0406017407baEd43652C440b304B858432B98') as Address,
  withdrawalDelaySecs: Number(process.env.WITHDRAWAL_DELAY_SECS || 60),
};

// L2ToL1MessagePasser address (constant across OP Stack)
const L2_TO_L1_MESSAGE_PASSER_ADDRESS = '0x4200000000000000000000000000000000000016' as Address;

// Create clients
const account = privateKeyToAccount(config.privateKey);
const l1Client = createPublicClient({ chain: sepolia, transport: http(config.l1RpcUrl) });
const l2Client = createPublicClient({ chain: optimismSepolia, transport: http(config.l2RpcUrl) });
const l1WalletClient = createWalletClient({
  account,
  chain: sepolia,
  transport: http(config.l1RpcUrl)
});

async function main() {
  console.log('🔍 OP Succinct Withdrawal Prover\n');
  console.log(`Transaction: ${txHash}`);
  console.log(`L1 Bridge: ${config.l1ETHBridgeAddress}`);
  console.log(`Rollup: ${config.rollupAddress}\n`);

  try {
    // Step 1: Get withdrawal data from transaction
    console.log('📋 Getting withdrawal data from transaction...\n');
    
    const receipt = await l2Client.getTransactionReceipt({ hash: txHash });
    
    // Find withdrawal event
    const withdrawalLog = receipt.logs.find(log => 
      log.address.toLowerCase() === L2_TO_L1_MESSAGE_PASSER_ADDRESS.toLowerCase()
    );
    
    if (!withdrawalLog) {
      throw new Error('No withdrawal found in transaction');
    }

    // Parse withdrawal data
    const to = `0x${withdrawalLog.topics[1]?.slice(26)}` as Address;
    const amount = BigInt(withdrawalLog.topics[2] || 0);
    
    // Get nonce
    const messageNonce = await l2Client.readContract({
      address: L2_TO_L1_MESSAGE_PASSER_ADDRESS,
      abi: [{ name: 'messageNonce', type: 'function', inputs: [], outputs: [{ type: 'uint256' }], stateMutability: 'view' }],
      functionName: 'messageNonce',
      blockNumber: receipt.blockNumber
    });
    const nonce = messageNonce - 1n; // Previous nonce
    
    console.log(`To: ${to}`);
    console.log(`Amount: ${formatEther(amount)} ETH`);
    console.log(`Nonce: ${nonce}\n`);

    // Step 2: Check withdrawal status
    console.log('🔍 Checking withdrawal status...\n');
    
    const status = await getWithdrawalStatusSuccinct(l1Client, {
      to,
      amount,
      nonce,
      bridgeAddress: config.l1ETHBridgeAddress
    });
    
    if (status.isFinalized) {
      console.log('✅ Withdrawal already finalized!');
      return;
    }
    
    if (!status.isProven) {
      // Step 3: Find canonical proposal
      console.log('🔎 Finding canonical proposal...\n');
      
      // Get output root proof from L2 state
      const l2Block = await l2Client.getBlock({ blockNumber: receipt.blockNumber });
      const proof = await l2Client.getProof({
        address: L2_TO_L1_MESSAGE_PASSER_ADDRESS,
        storageKeys: [],
        blockNumber: receipt.blockNumber
      });
      
      const outputRootProof: OutputRootProof = {
        version: '0x0000000000000000000000000000000000000000000000000000000000000000',
        stateRoot: proof.storageHash,
        messagePasserStorageRoot: proof.storageHash,
        latestBlockhash: l2Block.hash!
      };
      
      const proposalId = await findCanonicalProposal(l1Client, {
        outputRootProof,
        rollupAddress: config.rollupAddress
      });
      
      if (proposalId === null) {
        console.log('⏳ No canonical proposal found yet. The proposer needs to submit one.');
        console.log('Please wait for the next proposal submission and try again.');
        return;
      }
      
      console.log(`Found canonical proposal #${proposalId}\n`);
      
      // Step 4: Build and submit proof
      console.log('🔨 Building withdrawal proof...\n');
      
      const proofParams = await buildProveWithdrawalSuccinct(l1Client, {
        to,
        amount,
        nonce,
        proposalId: BigInt(proposalId),
        outputRoot: l2Block.hash!,
        l2BlockNumber: BigInt(receipt.blockNumber),
        bridgeAddress: config.l1ETHBridgeAddress,
        l2Client
      });
      
      console.log('📤 Submitting proof to L1...\n');
      
      const proveTx = await proveWithdrawalSuccinct(l1WalletClient, proofParams);
      console.log(`Proof transaction: ${proveTx}`);
      
      const proveReceipt = await l1Client.waitForTransactionReceipt({ hash: proveTx });
      if (proveReceipt.status === 'success') {
        console.log('✅ Withdrawal proven successfully!\n');
      } else {
        throw new Error('Proof transaction failed');
      }
    } else {
      console.log('✅ Withdrawal already proven\n');
    }
    
    // Step 5: Wait and finalize
    console.log('⏰ Checking if withdrawal can be finalized...\n');
    
    const updatedStatus = await getWithdrawalStatusSuccinct(l1Client, {
      to,
      amount,
      nonce,
      bridgeAddress: config.l1ETHBridgeAddress
    });
    
    if (updatedStatus.canFinalize) {
      console.log('💰 Finalizing withdrawal...\n');
      
      const finalizeTx = await finalizeWithdrawalSuccinct(l1WalletClient, {
        to,
        amount,
        nonce,
        bridgeAddress: config.l1ETHBridgeAddress
      });
      
      console.log(`Finalize transaction: ${finalizeTx}`);
      
      const finalizeReceipt = await l1Client.waitForTransactionReceipt({ hash: finalizeTx });
      if (finalizeReceipt.status === 'success') {
        console.log('✅ Withdrawal finalized! Funds have been transferred to L1.');
      } else {
        throw new Error('Finalize transaction failed');
      }
    } else {
      const timeRemaining = updatedStatus.provenWithdrawal!.provenAt + config.withdrawalDelaySecs - Math.floor(Date.now() / 1000);
      console.log(`⏳ Withdrawal proven but not ready to finalize yet.`);
      console.log(`   Must wait ${timeRemaining} more seconds.`);
      console.log(`   Run this script again after the delay to finalize.`);
    }
    
  } catch (error) {
    console.error('\n❌ Error:', error);
    process.exit(1);
  }
}

main();