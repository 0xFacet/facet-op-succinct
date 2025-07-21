import { 
  createPublicClient, 
  createWalletClient, 
  http,
  type Address,
  type Hash,
  parseEther,
  formatEther
} from 'viem';
import { mainnet, optimism } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
// These would be imported from 'viem/op-stack' once the PR is merged
// For now, showing the expected import path
// import { 
//   getWithdrawalStatusSuccinct,
//   findCanonicalProposal,
//   buildProveWithdrawalSuccinct,
//   proveWithdrawalSuccinct,
//   finalizeWithdrawalSuccinct,
//   type OutputRootProof
// } from 'viem/op-stack';

/**
 * Complete example showing how to prove and finalize a withdrawal
 * from OP-Succinct using the viem implementation.
 * 
 * This example demonstrates:
 * 1. Checking withdrawal status
 * 2. Finding the canonical proposal
 * 3. Building proof parameters automatically
 * 4. Proving the withdrawal on L1
 * 5. Finalizing the withdrawal to receive funds
 */

// Configuration
const config = {
  // Your private key (DO NOT commit this to git!)
  privateKey: process.env.PRIVATE_KEY as `0x${string}` || '0x...',
  
  // Contract addresses (replace with actual deployments)
  l1ETHBridgeAddress: process.env.L1_ETH_BRIDGE_ADDRESS as Address || '0x...',
  rollupAddress: process.env.ROLLUP_ADDRESS as Address || '0x...',
  
  // RPC endpoints
  l1RpcUrl: process.env.L1_RPC_URL || 'https://eth-mainnet.g.alchemy.com/v2/your-api-key',
  l2RpcUrl: process.env.L2_RPC_URL || 'https://opt-mainnet.g.alchemy.com/v2/your-api-key',
};

async function main() {
  console.log('OP-Succinct Withdrawal Example');
  console.log('==============================\n');

  // 1. Setup clients
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

  // 2. Withdrawal parameters
  // In a real scenario, these would come from your L2 withdrawal transaction
  const withdrawal = {
    to: account.address, // Recipient on L1
    amount: parseEther('0.1'), // Amount to withdraw
    nonce: 123n, // The nonce from your L2 withdrawal transaction
    l2BlockNumber: 123456789n, // The L2 block containing your withdrawal
  };

  console.log('Withdrawal Details:');
  console.log(`To: ${withdrawal.to}`);
  console.log(`Amount: ${formatEther(withdrawal.amount)} ETH`);
  console.log(`Nonce: ${withdrawal.nonce}`);
  console.log(`L2 Block: ${withdrawal.l2BlockNumber}`);
  console.log('');

  try {
    // 3. Check withdrawal status
    console.log('Checking withdrawal status...');
    
    // NOTE: Replace with actual viem import when available
    // const status = await getWithdrawalStatusSuccinct(l1Client, {
    //   to: withdrawal.to,
    //   amount: withdrawal.amount,
    //   nonce: withdrawal.nonce,
    //   bridgeAddress: config.l1ETHBridgeAddress,
    // });

    // For this example, we'll simulate the status
    const status: {
      withdrawalHash: Hash
      storageKey: Hash
      isProven: boolean
      isFinalized: boolean
      provenWithdrawal?: {
        proposalId: number
        provenAt: number
      }
    } = {
      withdrawalHash: '0x...' as Hash,
      storageKey: '0x...' as Hash,
      isProven: false,
      isFinalized: false,
      provenWithdrawal: undefined
    };

    console.log(`Withdrawal Hash: ${status.withdrawalHash}`);
    console.log(`Is Proven: ${status.isProven}`);
    console.log(`Is Finalized: ${status.isFinalized}`);
    console.log('');

    // 4. If not proven, prove the withdrawal
    if (!status.isProven) {
      console.log('Withdrawal not yet proven. Starting proof process...\n');

      // Get the L2 block data for the output root proof
      // In production, this would be fetched from the L2 block
      const outputRootProof = {
        version: '0x0000000000000000000000000000000000000000000000000000000000000000' as Hash,
        stateRoot: '0x...' as Hash, // From L2 block
        messagePasserStorageRoot: '0x...' as Hash, // From L2 state
        latestBlockhash: '0x...' as Hash, // L2 block hash
      };

      // Find the canonical proposal containing this output root
      console.log('Searching for canonical proposal...');
      
      // NOTE: Replace with actual viem import
      // const proposalId = await findCanonicalProposal(l1Client, {
      //   outputRootProof,
      //   rollupAddress: config.rollupAddress,
      // });
      
      const proposalId = 123n; // Simulated

      if (!proposalId) {
        console.error('No canonical proposal found with the given output root');
        console.log('The L2 state might not have been proposed yet. Please wait and try again.');
        return;
      }

      console.log(`Found canonical proposal: ${proposalId}\n`);

      // Build the proof parameters
      console.log('Building withdrawal proof parameters...');
      
      // NOTE: Replace with actual viem import
      // const proofParams = await buildProveWithdrawalSuccinct(l1Client, {
      //   to: withdrawal.to,
      //   amount: withdrawal.amount,
      //   nonce: withdrawal.nonce,
      //   proposalId,
      //   outputRoot: keccak256(encodeAbiParameters(...)), // Computed from outputRootProof
      //   l2BlockNumber: withdrawal.l2BlockNumber,
      //   bridgeAddress: config.l1ETHBridgeAddress,
      //   l2Client,
      // });

      // For this example, simulate the proof parameters
      const proofParams = {
        to: withdrawal.to,
        amount: withdrawal.amount,
        nonce: withdrawal.nonce,
        proposalId,
        outputRootProof,
        withdrawalProof: ['0x...'] as Hash[], // Merkle proof from L2 state
        bridgeAddress: config.l1ETHBridgeAddress,
      };

      console.log('Proof parameters ready\n');

      // Submit the proof to L1
      console.log('Submitting withdrawal proof to L1...');
      
      // NOTE: Replace with actual viem import
      // const hash = await proveWithdrawalSuccinct(l1WalletClient, proofParams);
      
      const hash = '0x...' as Hash; // Simulated transaction hash

      console.log(`Withdrawal proven! Transaction hash: ${hash}`);
      console.log('Waiting for confirmation...\n');

      // Wait for transaction confirmation
      const receipt = await l1Client.waitForTransactionReceipt({ hash });
      console.log(`Transaction confirmed in block ${receipt.blockNumber}`);
      console.log(`Gas used: ${receipt.gasUsed}`);
    } else {
      console.log('Withdrawal already proven');
      if (status.provenWithdrawal) {
        console.log(`Proposal ID: ${status.provenWithdrawal.proposalId}`);
        console.log(`Proven at: ${new Date(Number(status.provenWithdrawal.provenAt) * 1000).toISOString()}`);
      }
    }

    console.log('');

    // 5. If proven but not finalized, finalize the withdrawal
    if (status.isProven && !status.isFinalized) {
      console.log('Withdrawal proven but not finalized. Finalizing...\n');

      // NOTE: Replace with actual viem import
      // const hash = await finalizeWithdrawalSuccinct(l1WalletClient, {
      //   to: withdrawal.to,
      //   amount: withdrawal.amount,
      //   nonce: withdrawal.nonce,
      //   bridgeAddress: config.l1ETHBridgeAddress,
      // });

      const hash = '0x...' as Hash; // Simulated transaction hash

      console.log(`Withdrawal finalized! Transaction hash: ${hash}`);
      console.log('Waiting for confirmation...\n');

      const receipt = await l1Client.waitForTransactionReceipt({ hash });
      console.log(`Transaction confirmed in block ${receipt.blockNumber}`);
      console.log(`Gas used: ${receipt.gasUsed}`);
      console.log('\nFunds have been transferred to your L1 address!');
    } else if (status.isFinalized) {
      console.log('Withdrawal already finalized!');
    }

  } catch (error) {
    console.error('Error:', error);
    process.exit(1);
  }
}

// Helper function to wait for user confirmation
async function waitForConfirmation(message: string): Promise<boolean> {
  console.log(`\n${message} (y/n): `);
  
  return new Promise((resolve) => {
    process.stdin.once('data', (data) => {
      const answer = data.toString().trim().toLowerCase();
      resolve(answer === 'y' || answer === 'yes');
    });
  });
}

// Run the example
main().catch((error) => {
  console.error('Unhandled error:', error);
  process.exit(1);
});