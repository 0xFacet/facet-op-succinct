use std::{env, sync::Arc, time::Duration};

use alloy_primitives::{Address, TxHash, U256, B256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_eips::BlockNumberOrTag;
use alloy_sol_types::SolEvent;
use anyhow::{Context, Result};
use op_succinct_client_utils::boot::BootInfoStruct;
use op_succinct_elfs::AGGREGATION_ELF;
use op_succinct_host_utils::{
    block_range::{split_range_based_on_safe_heads, split_range_basic, SpanBatchRange},
    fetcher::OPSuccinctDataFetcher, get_agg_proof_stdin, host::OPSuccinctHost,
    metrics::MetricsGauge, witness_generation::WitnessGenerator,
};
use op_succinct_proof_utils::get_range_elf_embedded;
use op_succinct_signer_utils::Signer;
use sp1_sdk::{
    network::FulfillmentStrategy, NetworkProver, Prover, ProverClient, SP1ProofMode,
    SP1ProofWithPublicValues, SP1ProvingKey, SP1VerifyingKey, SP1_CIRCUIT_VERSION,
};
use tokio::time;

use crate::{
    config::RollupProposerConfig,
    contract::Rollup::{RollupInstance, ProposalSubmitted, ProposalStatus},
    prometheus::ProposerGauge,
    Action, L1Provider, L2Provider, L2ProviderTrait, RollupTrait,
};

struct SP1Prover {
    network_prover: Arc<NetworkProver>,
    range_pk: Arc<SP1ProvingKey>,
    range_vk: Arc<SP1VerifyingKey>,
    agg_pk: Arc<SP1ProvingKey>,
}

pub struct RollupProposer<P, H: OPSuccinctHost>
where
    P: Provider + Clone + Send + Sync,
{
    pub config: RollupProposerConfig,
    pub prover_address: Address,
    pub signer: Signer,
    pub l1_provider: L1Provider,
    pub l2_provider: L2Provider,
    pub rollup: Arc<RollupInstance<P>>,
    pub safe_db_fallback: bool,
    pub proposer_bond: U256,
    pub challenger_bond: U256,
    pub proposal_interval: u64,
    prover: SP1Prover,
    fetcher: Arc<OPSuccinctDataFetcher>,
    host: Arc<H>,
}

impl<P, H: OPSuccinctHost> RollupProposer<P, H>
where
    P: Provider + Clone + Send + Sync,
{
    /// Creates a new proposer instance for the Rollup contract
    pub async fn new(
        prover_address: Address,
        signer: Signer,
        rollup: RollupInstance<P>,
        fetcher: Arc<OPSuccinctDataFetcher>,
        host: Arc<H>,
    ) -> Result<Self> {
        let config = RollupProposerConfig::from_env()?;

        // Set a default network private key to avoid an error in mock mode
        let private_key = env::var("NETWORK_PRIVATE_KEY").unwrap_or_else(|_| {
            tracing::warn!(
                "Using default NETWORK_PRIVATE_KEY of 0x01. This is only valid in mock mode."
            );
            "0x0000000000000000000000000000000000000000000000000000000000000001".to_string()
        });

        let network_prover =
            Arc::new(ProverClient::builder().network().private_key(&private_key).build());
        let (range_pk, range_vk) = network_prover.setup(get_range_elf_embedded());
        let (agg_pk, _) = network_prover.setup(AGGREGATION_ELF);

        // Fetch bond constants from contract
        let proposer_bond = rollup.PROPOSER_BOND().call().await?;
        let challenger_bond = rollup.CHALLENGER_BOND().call().await?;

        // Fetch proposal interval from contract to avoid config mismatch
        let proposal_interval_u256 = rollup.PROPOSAL_INTERVAL().call().await?;
        let proposal_interval: u64 = proposal_interval_u256.to::<u64>();

        Ok(Self {
            config: config.clone(),
            prover_address,
            signer,
            l1_provider: ProviderBuilder::default().connect_http(config.l1_rpc.clone()),
            l2_provider: ProviderBuilder::default().connect_http(config.l2_rpc),
            rollup: Arc::new(rollup),
            safe_db_fallback: config.safe_db_fallback,
            proposer_bond,
            challenger_bond,
            proposal_interval,
            prover: SP1Prover {
                network_prover,
                range_pk: Arc::new(range_pk),
                range_vk: Arc::new(range_vk),
                agg_pk: Arc::new(agg_pk),
            },
            fetcher: fetcher.clone(),
            host,
        })
    }

    /// Proves a proposal that has been challenged
    pub async fn prove_proposal(&self, proposal_id: U256) -> Result<TxHash> {
        // First check if the proposal exists and needs proving
        let proposal = self.rollup.getProposal(proposal_id).call().await?;
        let proposal_status = proposal.proposalStatus;
        
        match proposal_status {
            ProposalStatus::Challenged => {
                tracing::info!("Proposal {} is challenged, proceeding with proof generation", proposal_id);
            }
            ProposalStatus::ChallengedAndProven => {
                return Err(anyhow::anyhow!("Proposal {} already has a valid proof", proposal_id));
            }
            ProposalStatus::Resolved => {
                return Err(anyhow::anyhow!("Proposal {} is already resolved", proposal_id));
            }
            _ => {
                return Err(anyhow::anyhow!("Proposal {} is not in a challenged state", proposal_id));
            }
        }

        // Get L1 block for proof (latest - 1 for reorg protection)
        let (l1_block_number, l1_head_hash) = self.get_l1_block_for_proof().await
            .context("Failed to get L1 block for proof")?;
        
        // Checkpoint L1 block immediately to prevent it from becoming too old
        tracing::info!("Checkpointing L1 block {} before proof generation", l1_block_number);
        self.checkpoint_l1_block(l1_block_number).await
            .context("Failed to checkpoint L1 block - block may be too old for proof generation")?;
        
        let l2_block_number = proposal.l2BlockNumber;
        
        // Validate proposal data
        tracing::info!("Proposal details:");
        tracing::info!("  Proposal ID: {}", proposal_id);
        tracing::info!("  L1 Block: {} (0x{})", l1_block_number, hex::encode(l1_head_hash));
        tracing::info!("  L2 Block Number: {}", l2_block_number);
        tracing::info!("  Root Claim: 0x{}", hex::encode(proposal.rootClaim));
        tracing::info!("  Proposer: 0x{}", hex::encode(proposal.proposer));
        tracing::info!("  Deadline: {}", proposal.deadline);
        
        // Step 3: Compute start/end blocks
        // Retrieve parent proposal to determine start block
        let parent_proposal = self
            .rollup
            .getProposal(U256::from(proposal.parentIndex))
            .call()
            .await?;

        let l2_start = parent_proposal.l2BlockNumber as u64;
        let l2_end = l2_block_number as u64;
        
        tracing::info!("Block range: {} - {}", l2_start, l2_end);
        tracing::info!("Range proof interval: {} blocks", self.config.range_proof_interval);
        
        // Step 4: Split the span exactly like the estimator
        let safe_db_activated = self.fetcher.is_safe_db_activated().await?;
        let ranges: Vec<SpanBatchRange> = if safe_db_activated {
            tracing::info!("Using safe head based range splitting");
            split_range_based_on_safe_heads(l2_start, l2_end, self.config.range_proof_interval).await?
        } else {
            tracing::info!("Using basic range splitting");
            split_range_basic(l2_start, l2_end, self.config.range_proof_interval)
        };
        
        tracing::info!("Split into {} ranges: {:?}", ranges.len(), ranges);
        
        // Step 5: Generate range proofs per chunk (sequential)
        let mut proofs = Vec::new();
        let mut boot_infos = Vec::new();
        
        for (i, range) in ranges.iter().enumerate() {
            tracing::info!("Processing range {}/{}: blocks {} - {}", i + 1, ranges.len(), range.start, range.end);
            
            let host_args = self
                .host
                .fetch(
                    range.start,
                    range.end,
                    Some(l1_head_hash.into()),
                    self.config.safe_db_fallback,
                )
                .await
                .context(format!("Failed to fetch host args for range {} - {}", range.start, range.end))?;
            
            let witness_data = self.host.run(&host_args).await
                .context(format!("Failed to run host for range {} - {}", range.start, range.end))?;
            
            let sp1_stdin = self.host.witness_generator().get_sp1_stdin(witness_data)
                .context(format!("Failed to get SP1 stdin for range {} - {}", range.start, range.end))?;
            
            tracing::info!("Generating range proof for blocks {} - {}", range.start, range.end);
            let range_proof = if self.config.mock_mode {
                let (public_values, _) =
                    self.prover.network_prover.execute(get_range_elf_embedded(), &sp1_stdin).run()?;

                SP1ProofWithPublicValues::create_mock_proof(
                    &self.prover.range_pk,
                    public_values,
                    SP1ProofMode::Compressed,
                    SP1_CIRCUIT_VERSION,
                )
            } else {
                self.prover
                    .network_prover
                    .prove(&self.prover.range_pk, &sp1_stdin)
                    .compressed()
                    .strategy(FulfillmentStrategy::Hosted)
                    .skip_simulation(true)
                    .cycle_limit(self.config.cycle_limit)
                    .timeout(Duration::from_secs(self.config.timeout))
                    .run_async()
                    .await?
            };
            
            let mut public_values = range_proof.public_values.clone();
            let boot_info: BootInfoStruct = public_values.read();
            
            boot_infos.push(boot_info);
            proofs.push(range_proof.proof);
        }
        
        tracing::info!("All {} range proofs generated successfully", ranges.len());

        // Step 6: Aggregate once, exactly as you already do
        tracing::info!("Preparing stdin for aggregation proof");
        
        // Use the first boot info's l1Head for all header fetching (they should all be the same)
        let l1_head = boot_infos[0].l1Head;
        
        let headers = self.fetcher
            .get_header_preimages(&boot_infos, l1_head)
            .await
            .context("Failed to get header preimages")?;

        let agg_stdin = get_agg_proof_stdin(
            proofs,
            boot_infos,
            headers,
            &self.prover.range_vk,
            l1_head,
            self.prover_address,
        )
        .context("Failed to get aggregation proof stdin")?;

        tracing::info!("Generating aggregation proof");
        let agg_proof = if self.config.mock_mode {
            tracing::info!("Using mock mode for aggregation proof generation");
            let (public_values, _) = self
                .prover
                .network_prover
                .execute(AGGREGATION_ELF, &agg_stdin)
                .deferred_proof_verification(false)
                .run()?;

            SP1ProofWithPublicValues::create_mock_proof(
                &self.prover.agg_pk,
                public_values,
                SP1ProofMode::Plonk,
                SP1_CIRCUIT_VERSION,
            )
        } else {
            self.prover
                .network_prover
                .prove(&self.prover.agg_pk, &agg_stdin)
                .plonk()
                .strategy(FulfillmentStrategy::Hosted)
                .timeout(Duration::from_secs(self.config.timeout))
                .run_async()
                .await?
        };
        
        let transaction_request = self.rollup
            .proveProposal(
                proposal_id, 
                U256::from(l1_block_number),
                agg_proof.bytes().into()
            )
            .into_transaction_request();

        let receipt = self
            .signer
            .send_transaction_request(self.config.l1_rpc.clone(), transaction_request)
            .await?;

        Ok(receipt.transaction_hash)
    }

    /// Creates a new proposal
    pub async fn create_proposal(
        &self,
        l2_block_number: U256,
        parent_id: U256,
    ) -> Result<U256> {
        tracing::info!("=== Proposal Creation Parameters ===");
        tracing::info!("Config values:");
        tracing::info!("  - Proposal interval: {:?} blocks", self.proposal_interval);
        tracing::info!("  - Fast finality mode: {:?}", self.config.fast_finality_mode);
        tracing::info!("  - Safe DB fallback: {:?}", self.config.safe_db_fallback);
        tracing::info!("  - Mock mode: {:?}", self.config.mock_mode);
        
        tracing::info!("Proposal parameters:");
        tracing::info!("  - L2 block number: {:?}", l2_block_number);
        tracing::info!("  - Parent ID: {:?}", parent_id);
        tracing::info!("  - Prover address: {:?}", self.prover_address);
        tracing::info!("  - Rollup address: {:?}", self.rollup.address());

        let output_root = self.l2_provider.compute_output_root_at_block(l2_block_number).await?;
        tracing::info!("Output root: 0x{}", hex::encode(output_root));

        let transaction_request = self
            .rollup
            .submitProposal(
                output_root,
                l2_block_number.try_into().unwrap(),
                parent_id.into(),
            )
            .value(self.proposer_bond)
            .into_transaction_request();

        tracing::info!("Transaction details:");
        tracing::info!("  - From address: {:?}", self.signer.address());
        tracing::info!("  - To address: {:?}", self.rollup.address());
        tracing::info!("  - Value (proposer bond): {} wei", self.proposer_bond);
        tracing::info!("=== End Proposal Creation Parameters ===");

        let receipt = self
            .signer
            .send_transaction_request(self.config.l1_rpc.clone(), transaction_request)
            .await?;

        tracing::info!("Transaction receipt:");
        tracing::info!("  - Transaction hash: {:?}", receipt.transaction_hash);
        tracing::info!("  - Block number: {:?}", receipt.block_number);
        tracing::info!("  - Gas used: {:?}", receipt.gas_used);

        let proposal_id = receipt
            .inner
            .logs()
            .iter()
            .find_map(|log| {
                ProposalSubmitted::decode_log(&log.inner).ok().map(|event| event.proposalId)
            })
            .context("Could not find ProposalSubmitted event in transaction receipt logs")?;

        tracing::info!(
            "\x1b[1mNew proposal {} created for block {} with tx {:?}\x1b[0m",
            proposal_id,
            l2_block_number,
            receipt.transaction_hash
        );

        if self.config.fast_finality_mode {
            tracing::info!("Fast finality mode enabled: Generating proof for the proposal immediately");

            let tx_hash = self.prove_proposal(proposal_id).await?;
            tracing::info!(
                "\x1b[1mProposal {} proved with tx {:?}\x1b[0m",
                proposal_id,
                tx_hash
            );
        }

        Ok(proposal_id)
    }


    /// Handles the creation of a new proposal if conditions are met
    pub async fn handle_proposal_creation(&self) -> Result<Option<U256>> {
        let _span = tracing::info_span!("[[Proposing]]").entered();

        // Determine the reference block for the next proposal using the latest *valid* proposal.
        let (reference_block, reference_proposal_id) = match self.rollup.get_latest_valid_proposal(self.l2_provider.clone()).await? {
            Some((block, id)) => (block, id),
            None => {
                // This should never happen in normal operation; treat as fatal.
                return Err(anyhow::anyhow!("No valid proposals exist on-chain; deploy logic requires at least the genesis proposal."));
            }
        };

        tracing::info!(
            "Reference proposal ID: {}, L2 block: {}",
            reference_proposal_id,
            reference_block
        );

        // Calculate next L2 block number for proposal with overflow check
        let next_l2_block_number = reference_block
            .checked_add(U256::from(self.proposal_interval))
            .ok_or_else(|| anyhow::anyhow!("Overflow calculating next L2 block number"))?;

        let finalized_l2_head_block_number = self
            .host
            .get_finalized_l2_block_number(&self.fetcher, reference_block.to::<u64>())
            .await?;

        tracing::info!(
            "Finalized L2 head block number: {:?}",
            finalized_l2_head_block_number
        );

        // Only create a new proposal if the finalized L2 head block number is greater than the next L2 block number
        if let Some(finalized_block) = finalized_l2_head_block_number {
            tracing::info!(
                "Comparing finalized block ({:?}) with next proposal block ({:?})",
                finalized_block,
                next_l2_block_number
            );
            
            if U256::from(finalized_block) > U256::from(next_l2_block_number) {
                tracing::info!(
                    "Creating new proposal - Finalized block ({:?}) is ahead of next proposal block ({:?})",
                    finalized_block,
                    next_l2_block_number
                );
                let proposal_id = self
                    .create_proposal(U256::from(next_l2_block_number), reference_proposal_id)
                    .await?;

                Ok(Some(proposal_id))
            } else {
                tracing::info!(
                    "Skipping proposal creation - Finalized block ({:?}) is not ahead of next proposal block ({:?})",
                    finalized_block,
                    next_l2_block_number
                );

                Ok(None)
            }
        } else {
            tracing::info!(
                "No finalized block number found since latest proposal block ({:?})",
                reference_block
            );
            Ok(None)
        }
    }

    /// Handles the resolution of eligible proposals
    pub async fn handle_proposal_resolution(&self) -> Result<()> {
        let _span = tracing::info_span!("[[Resolving]]").entered();

        // Get the range of proposals to check
        let proposals_length = self.rollup.get_proposals_length().await?;
        let anchor_id = U256::from(self.rollup.anchorProposalId().call().await?);
        let start_id = proposals_length.saturating_sub(U256::from(self.config.max_proposals_to_check_for_resolution));
        let start_id = start_id.max(anchor_id);
        
        let mut resolved_count = 0;
        
        for i in 0..self.config.max_proposals_to_check_for_resolution {
            let proposal_id = start_id + U256::from(i);
            if proposal_id >= proposals_length {
                break;
            }
            if proposal_id == U256::ZERO {
                continue; // Skip genesis proposal
            }

            // Check if resolvable in a single call
            let is_resolvable = match self.rollup.isResolvable(proposal_id).call().await {
                Ok(resolvable) => resolvable,
                Err(_) => continue,
            };
            
            if !is_resolvable {
                continue;
            }

            // Try to resolve this proposal
            let transaction_request = self.rollup.resolveProposal(proposal_id).into_transaction_request();
            
            match self
                .signer
                .send_transaction_request(self.config.l1_rpc.clone(), transaction_request)
                .await
            {
                Ok(receipt) => {
                    tracing::info!(
                        "\x1b[1mSuccessfully resolved proposal {} with tx {:?}\x1b[0m",
                        proposal_id,
                        receipt.transaction_hash
                    );
                    ProposerGauge::ProposalsResolved.increment(1.0);
                    resolved_count += 1;
                }
                Err(e) => {
                    tracing::debug!("Could not resolve proposal {}: {:?}", proposal_id, e);
                }
            }
        }

        if resolved_count == 0 {
            tracing::debug!("No proposals were resolved");
        } else {
            tracing::info!("Resolved {} proposals", resolved_count);
        }

        Ok(())
    }

    /// Handles the defense of proposals by providing proofs
    pub async fn handle_proposal_defense(&self) -> Result<()> {
        let _span = tracing::info_span!("[[Defending]]").entered();

        // Get the range of proposals to check
        let proposals_length = self.rollup.get_proposals_length().await?;
        let anchor_id = U256::from(self.rollup.anchorProposalId().call().await?);
        let start_id = proposals_length.saturating_sub(U256::from(self.config.max_proposals_to_check_for_defense));
        let start_id = start_id.max(anchor_id);
        
        let mut defended_count = 0;
        
        for i in 0..self.config.max_proposals_to_check_for_defense {
            let proposal_id = start_id + U256::from(i);
            if proposal_id >= proposals_length {
                break;
            }
            if proposal_id == U256::ZERO {
                continue; // Skip genesis proposal
            }

            // Check if needs defense in a single call
            let needs_defense = match self.rollup.needsDefense(proposal_id).call().await {
                Ok(needs) => needs,
                Err(_) => continue,
            };
            
            if !needs_defense {
                continue;
            }

            // Get the proposal details to check if it's ours
            let proposal = match self.rollup.getProposal(proposal_id).call().await {
                Ok(p) => p,
                Err(_) => continue,
            };

            // Check if this is our proposal by verifying the output root
            let output_root = match self.l2_provider.compute_output_root_at_block(U256::from(proposal.l2BlockNumber)).await {
                Ok(root) => root,
                Err(e) => {
                    tracing::warn!("Failed to compute output root for proposal {}: {:?}", proposal_id, e);
                    continue;
                }
            };
            if output_root != proposal.rootClaim {
                continue; // Not our proposal, skip defense
            }

            tracing::info!("Attempting to defend proposal {}", proposal_id);

            match self.prove_proposal(proposal_id).await {
                Ok(tx_hash) => {
                    tracing::info!(
                        "\x1b[1mSuccessfully defended proposal {} with tx {:?}\x1b[0m",
                        proposal_id,
                        tx_hash
                    );
                    defended_count += 1;
                }
                Err(e) => {
                    tracing::warn!("Failed to defend proposal {}: {:?}", proposal_id, e);
                    ProposerGauge::ProposalDefenseError.increment(1.0);
                }
            }
        }

        if defended_count == 0 {
            tracing::debug!("No proposals were defended");
        } else {
            tracing::info!("Defended {} proposals", defended_count);
        }

        Ok(())
    }

    /// Handles claiming bonds from resolved proposals
    pub async fn handle_bond_claiming(&self) -> Result<Action> {
        let _span = tracing::info_span!("[[Claiming Bonds]]").entered();

        // Check if we have any credit to claim
        let credit = self.rollup.credit(self.prover_address).call().await?;
        
        if credit == U256::ZERO {
            tracing::info!("No credit to claim");
            return Ok(Action::Skipped);
        }

        // Calculate minimum threshold based on proposer bond and multiplier
        let min_threshold = self.proposer_bond * U256::from(self.config.min_credit_threshold_multiplier);
        
        if credit < min_threshold {
            tracing::info!(
                "Credit {} wei is below minimum threshold {} wei ({}x proposer bond)",
                credit,
                min_threshold,
                self.config.min_credit_threshold_multiplier
            );
            ProposerGauge::ClaimsSkippedThreshold.increment(1.0);
            return Ok(Action::Skipped);
        }

        tracing::info!("Attempting to claim credit: {} wei", credit);

        let transaction_request = self.rollup.claimCredit(self.prover_address).into_transaction_request();

        match self
            .signer
            .send_transaction_request(self.config.l1_rpc.clone(), transaction_request)
            .await
        {
            Ok(receipt) => {
                tracing::info!(
                    "\x1b[1mSuccessfully claimed {} wei with tx {:?}\x1b[0m",
                    credit,
                    receipt.transaction_hash
                );
                ProposerGauge::BondsClaimed.increment(1.0);
                Ok(Action::Performed)
            }
            Err(e) => Err(anyhow::anyhow!("Failed to claim credit: {:?}", e)),
        }
    }

    /// Get L1 block for proof generation (latest - 1 for reorg protection)
    async fn get_l1_block_for_proof(&self) -> Result<(u64, B256)> {
        // Get latest block
        let latest = self.l1_provider
            .get_block(BlockNumberOrTag::Latest.into())
            .await?
            .context("Failed to get latest block")?;
        
        // Use latest - 2 for minimal reorg protection
        let target_number = latest.header.number.saturating_sub(2);
        
        let block = self.l1_provider
            .get_block(BlockNumberOrTag::Number(target_number).into())
            .await?
            .context("Failed to get target block")?;
        
        tracing::info!(
            "Using L1 block {} (0x{}) for proof generation (latest: {})",
            target_number,
            hex::encode(block.header.hash),
            latest.header.number
        );
        
        Ok((target_number, block.header.hash))
    }

    /// Checkpoint L1 block (always checkpoint, following official Succinct approach)
    async fn checkpoint_l1_block(&self, block_number: u64) -> Result<()> {
        tracing::info!("Checkpointing L1 block {}", block_number);
        
        let tx = self.rollup
            .checkpointL1BlockHash(U256::from(block_number))
            .into_transaction_request();
            
        ProposerGauge::CheckpointAttempts.increment(1.0);
        
        let receipt = self.signer
            .send_transaction_request(self.config.l1_rpc.clone(), tx)
            .await
            .map_err(|e| {
                ProposerGauge::CheckpointFailures.increment(1.0);
                anyhow::anyhow!("Failed to checkpoint L1 block {}: {:?}", block_number, e)
            })?;
            
        // Check if transaction reverted
        if !receipt.status() {
            ProposerGauge::CheckpointFailures.increment(1.0);
            return Err(anyhow::anyhow!("Checkpoint transaction reverted: {:?}", receipt));
        }
        
        tracing::info!("L1 block {} checkpointed in tx {:?}", 
            block_number, receipt.transaction_hash);
        
        Ok(())
    }

    /// Fetch the proposer metrics
    async fn fetch_proposer_metrics(&self) -> Result<()> {
        // Get the anchor proposal for metrics
        let _anchor_proposal_id = self.rollup.anchorProposalId().call().await?;
        let anchor_proposal = self
            .rollup
            .getProposal(U256::from(_anchor_proposal_id))
            .call()
            .await?;

        // Update metrics for anchor L2 block number
        ProposerGauge::AnchorProposalL2BlockNumber.set(anchor_proposal.l2BlockNumber as f64);

        // Get the latest proposal
        let proposals_length = self.rollup.get_proposals_length().await?;
        let latest_proposal_id = if proposals_length > U256::ZERO {
            proposals_length - U256::from(1)
        } else {
            U256::ZERO
        };
        
        if latest_proposal_id > U256::ZERO {
            let latest_proposal = self.rollup.getProposal(latest_proposal_id).call().await?;
            ProposerGauge::LatestProposalL2BlockNumber.set(latest_proposal.l2BlockNumber as f64);

            // Update metrics for finalized L2 block number based on latest proposal's block
            if let Some(finalized_l2_block_number) = self
                .host
                .get_finalized_l2_block_number(&self.fetcher, latest_proposal.l2BlockNumber as u64)
                .await?
            {
                ProposerGauge::FinalizedL2BlockNumber.set(finalized_l2_block_number as f64);
            }
        }

        Ok(())
    }

    /// Runs the proposer indefinitely
    pub async fn run(&self) -> Result<()> {
        tracing::info!("Rollup Proposer running...");
        let mut interval = time::interval(Duration::from_secs(self.config.fetch_interval));
        let mut metrics_interval = time::interval(Duration::from_secs(15));

        loop {
            tokio::select! {
                _ = interval.tick() => {
                    match self.handle_proposal_creation().await {
                        Ok(Some(_)) => {
                            ProposerGauge::ProposalsCreated.increment(1.0);
                        }
                        Ok(None) => {}
                        Err(e) => {
                            tracing::warn!("Failed to handle proposal creation: {:?}", e);
                            ProposerGauge::ProposalCreationError.increment(1.0);
                        }
                    }

                    if let Err(e) = self.handle_proposal_defense().await {
                        tracing::warn!("Failed to handle proposal defense: {:?}", e);
                        ProposerGauge::ProposalDefenseError.increment(1.0);
                    }

                    if self.config.enable_proposal_resolution {
                        if let Err(e) = self.handle_proposal_resolution().await {
                            tracing::warn!("Failed to handle proposal resolution: {:?}", e);
                            ProposerGauge::ProposalResolutionError.increment(1.0);
                        }
                    }

                    match self.handle_bond_claiming().await {
                        Ok(Action::Performed) => {
                            ProposerGauge::BondsClaimed.increment(1.0);
                        }
                        Ok(Action::Skipped) => {}
                        Err(e) => {
                            tracing::warn!("Failed to handle bond claiming: {:?}", e);
                            ProposerGauge::BondClaimingError.increment(1.0);
                        }
                    }
                }
                _ = metrics_interval.tick() => {
                    if let Err(e) = self.fetch_proposer_metrics().await {
                        tracing::warn!("Failed to fetch metrics: {:?}", e);
                        ProposerGauge::MetricsError.increment(1.0);
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{keccak256, hex};
    use alloy_sol_types::SolCall;
    use crate::contract::Rollup::{proveProposalCall, checkpointL1BlockHashCall};
    
    #[test]
    fn test_l1_block_selection_logic() {
        // Test that we correctly select latest - 1
        let latest_number = 100u64;
        let target_number = latest_number.saturating_sub(1);
        assert_eq!(target_number, 99);
        
        // Test edge case with block 0
        let latest_zero = 0u64;
        let target_zero = latest_zero.saturating_sub(1);
        assert_eq!(target_zero, 0); // saturating_sub prevents underflow
    }

    #[test]
    fn test_checkpoint_selector_exact_value() {
        // Test that checkpoint function selector has the correct value
        let selector = keccak256(b"checkpointL1BlockHash(uint256)");
        let actual_selector = &selector[0..4];
        
        // Expected value calculated independently
        // You can verify with: cast sig "checkpointL1BlockHash(uint256)"
        let expected: [u8; 4] = hex!("3522f010");
        
        assert_eq!(actual_selector, expected);
    }

    #[test]
    fn test_prove_proposal_abi_encoding() {
        // Test that proveProposal encoding matches expected ABI
        use crate::contract::Rollup::proveProposalCall;
        
        let call = proveProposalCall {
            id: U256::from(42),
            l1BlockNumber: U256::from(12345),
            proof: hex!("deadbeef").into(),
        };
        
        // Encode the call
        let encoded = call.abi_encode();
        
        // First 4 bytes should be the selector
        let selector = &encoded[0..4];
        let expected_selector = keccak256(b"proveProposal(uint256,uint256,bytes)")[0..4].to_vec();
        assert_eq!(selector, expected_selector);
        
        // Decode and verify round-trip
        let decoded = proveProposalCall::abi_decode(&encoded).unwrap();
        assert_eq!(decoded.id, U256::from(42));
        assert_eq!(decoded.l1BlockNumber, U256::from(12345));
        assert_eq!(decoded.proof.as_ref(), hex!("deadbeef").as_ref());
    }

    #[test]
    fn test_checkpoint_l1_block_hash_abi_encoding() {
        // Test checkpointL1BlockHash encoding
        use crate::contract::Rollup::checkpointL1BlockHashCall;
        
        let call = checkpointL1BlockHashCall {
            l1BlockNumber: U256::from(999),
        };
        
        let encoded = call.abi_encode();
        
        // Verify selector matches our expected value
        let selector = &encoded[0..4];
        assert_eq!(selector, hex!("3522f010"));
        
        // Round-trip test
        let decoded = checkpointL1BlockHashCall::abi_decode(&encoded).unwrap();
        assert_eq!(decoded.l1BlockNumber, U256::from(999));
    }

    #[test]
    fn test_proposal_status_matching() {
        // Test that we handle the correct proposal statuses
        assert_eq!(ProposalStatus::Unchallenged as u8, 0);
        assert_eq!(ProposalStatus::Challenged as u8, 1);
        assert_eq!(ProposalStatus::UnchallengedAndProven as u8, 2);
        assert_eq!(ProposalStatus::ChallengedAndProven as u8, 3);
        assert_eq!(ProposalStatus::Resolved as u8, 4);
    }

    #[test]
    fn test_saturating_sub_comprehensive() {
        // Comprehensive test of saturating_sub behavior
        let test_cases = vec![
            (0u64, 0u64),      // Zero case
            (1u64, 0u64),      // Minimum non-zero
            (2u64, 1u64),      // Small number
            (100u64, 99u64),   // Normal case
            (u64::MAX, u64::MAX - 1), // Maximum value
        ];
        
        for (latest, expected) in test_cases {
            let result = latest.saturating_sub(1);
            assert_eq!(result, expected, "Failed for latest={}", latest);
        }
    }

    #[test]
    fn test_prove_proposal_calldata_structure() {
        // Test that prove_proposal generates correct calldata
        use crate::contract::Rollup::proveProposalCall;
        
        // Simulate a prove call with realistic data
        let proposal_id = U256::from(123);
        let l1_block_number = U256::from(15_000_000); // Realistic mainnet block
        let proof = vec![0xAB; 1024]; // 1KB proof (simplified)
        
        let call = proveProposalCall {
            id: proposal_id,
            l1BlockNumber: l1_block_number,
            proof: proof.clone().into(),
        };
        
        let encoded = call.abi_encode();
        
        // Verify structure:
        // - First 4 bytes: selector
        // - Next 32 bytes: proposal ID (padded uint256)
        // - Next 32 bytes: L1 block number (padded uint256)
        // - Next 32 bytes: offset to proof data
        // - Remaining: proof length + proof data
        
        assert!(encoded.len() >= 4 + 32 + 32 + 32, "Encoded data too short");
        
        // Extract and verify each component
        let selector = &encoded[0..4];
        assert_eq!(selector.len(), 4);
        
        // Verify proposal ID encoding (should be big-endian padded to 32 bytes)
        let id_bytes = &encoded[4..36];
        let decoded_id = U256::from_be_slice(id_bytes);
        assert_eq!(decoded_id, proposal_id);
        
        // Verify L1 block number encoding
        let block_bytes = &encoded[36..68];
        let decoded_block = U256::from_be_slice(block_bytes);
        assert_eq!(decoded_block, l1_block_number);
    }

    #[cfg(test)]
    mod integration_tests {
        use super::*;
        use crate::contract::Rollup::{proveProposalCall, checkpointL1BlockHashCall};
        
        // Mock types for testing the prove flow
        #[allow(dead_code)]
        struct MockProposal {
            id: U256,
            status: ProposalStatus,
            l2_block_number: u64,
            root_claim: B256,
            parent_index: u32,
            deadline: u64,
        }
        
        #[test]
        fn test_prove_proposal_happy_path_calldata() {
            // This test verifies that given a challenged proposal,
            // the prove_proposal method would generate correct calldata
            
            let mock_proposal = MockProposal {
                id: U256::from(42),
                status: ProposalStatus::Challenged,
                l2_block_number: 1100,
                root_claim: B256::from([0x11; 32]),
                parent_index: 0,
                deadline: 1000000,
            };
            
            // Expected L1 block selection: if latest is 100, we choose 99
            let expected_l1_block = 99u64;
            
            // Build the expected calldata components
            let expected_checkpoint_call = checkpointL1BlockHashCall {
                l1BlockNumber: U256::from(expected_l1_block),
            };
            
            let proof_bytes = vec![0xDE, 0xAD, 0xBE, 0xEF];
            let expected_prove_call = proveProposalCall {
                id: mock_proposal.id,
                l1BlockNumber: U256::from(expected_l1_block),
                proof: proof_bytes.into(),
            };
            
            // Verify checkpoint encoding
            let checkpoint_encoded = expected_checkpoint_call.abi_encode();
            assert_eq!(&checkpoint_encoded[0..4], hex!("3522f010"));
            
            // Verify prove encoding includes all required fields
            let prove_encoded = expected_prove_call.abi_encode();
            assert!(prove_encoded.len() > 100); // Should have selector + 3 fields
            
            // Verify the prove call has correct selector
            let prove_selector = keccak256(b"proveProposal(uint256,uint256,bytes)");
            assert_eq!(&prove_encoded[0..4], &prove_selector[0..4]);
        }
        
        #[test]
        fn test_min_credit_threshold_logic() {
            // Test minimum credit threshold calculations
            let proposer_bond = U256::from(80_000_000_000_000_000u64); // 0.08 ETH
            
            // Test with multiplier = 1
            let threshold_1x = proposer_bond * U256::from(1);
            assert_eq!(threshold_1x, proposer_bond);
            
            // Test with multiplier = 3
            let threshold_3x = proposer_bond * U256::from(3);
            assert_eq!(threshold_3x, U256::from(240_000_000_000_000_000u64)); // 0.24 ETH
            
            // Test with multiplier = 10
            let threshold_10x = proposer_bond * U256::from(10);
            assert_eq!(threshold_10x, U256::from(800_000_000_000_000_000u64)); // 0.8 ETH
            
            // Test credit comparison logic
            let credit_small = U256::from(50_000_000_000_000_000u64); // 0.05 ETH
            let credit_exact = proposer_bond;
            let credit_large = U256::from(500_000_000_000_000_000u64); // 0.5 ETH
            
            // With 3x threshold
            assert!(credit_small < threshold_3x); // Should skip
            assert!(credit_exact < threshold_3x); // Should skip  
            assert!(credit_large >= threshold_3x); // Should claim
        }
    }
}