use std::{env, sync::Arc, time::Duration};

use alloy_primitives::{Address, TxHash, U256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_sol_types::SolEvent;
use anyhow::{Context, Result};
use op_succinct_client_utils::boot::BootInfoStruct;
use op_succinct_elfs::AGGREGATION_ELF;
use op_succinct_host_utils::{
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
            ProposalStatus::ChallengedAndValidProofProvided => {
                return Err(anyhow::anyhow!("Proposal {} already has a valid proof", proposal_id));
            }
            ProposalStatus::Resolved => {
                return Err(anyhow::anyhow!("Proposal {} is already resolved", proposal_id));
            }
            _ => {
                return Err(anyhow::anyhow!("Proposal {} is not in a challenged state", proposal_id));
            }
        }
        let fetcher = match OPSuccinctDataFetcher::new_with_rollup_config().await {
            Ok(f) => f,
            Err(e) => {
                tracing::error!("Failed to create data fetcher: {}", e);
                return Err(anyhow::anyhow!("Failed to create data fetcher: {}", e));
            }
        };

        // Get proposal details
        let proposal = self.rollup.getProposal(proposal_id).call().await?;
        let l1_head_hash = proposal.l1Head;
        tracing::debug!("L1 head hash: {:?}", hex::encode(l1_head_hash));
        let l2_block_number = proposal.l2BlockNumber;

        let host_args = self
            .host
            .fetch(
                l2_block_number as u64 - self.config.proposal_interval_in_blocks,
                l2_block_number as u64,
                Some(l1_head_hash),
                self.config.safe_db_fallback,
            )
            .await
            .context("Failed to get host CLI args")?;

        let witness_data = self.host.run(&host_args).await?;

        let sp1_stdin = match self.host.witness_generator().get_sp1_stdin(witness_data) {
            Ok(stdin) => stdin,
            Err(e) => {
                tracing::error!("Failed to get proof stdin: {}", e);
                return Err(anyhow::anyhow!("Failed to get proof stdin: {}", e));
            }
        };

        tracing::info!("Generating Range Proof");
        let range_proof = if self.config.mock_mode {
            tracing::info!("Using mock mode for range proof generation");
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
                .cycle_limit(19_000_000_000)
                .run_async()
                .await?
        };

        tracing::info!("Preparing Stdin for Agg Proof");
        let proof = range_proof.proof.clone();
        let mut public_values = range_proof.public_values.clone();
        let boot_info: BootInfoStruct = public_values.read();

        let headers = match fetcher
            .get_header_preimages(&vec![boot_info.clone()], boot_info.clone().l1Head)
            .await
        {
            Ok(headers) => headers,
            Err(e) => {
                tracing::error!("Failed to get header preimages: {}", e);
                return Err(anyhow::anyhow!("Failed to get header preimages: {}", e));
            }
        };

        let sp1_stdin = match get_agg_proof_stdin(
            vec![proof],
            vec![boot_info.clone()],
            headers,
            &self.prover.range_vk,
            boot_info.l1Head,
            self.prover_address,
        ) {
            Ok(s) => s,
            Err(e) => {
                tracing::error!("Failed to get agg proof stdin: {}", e);
                return Err(anyhow::anyhow!("Failed to get agg proof stdin: {}", e));
            }
        };

        tracing::info!("Generating Agg Proof");
        let agg_proof = if self.config.mock_mode {
            tracing::info!("Using mock mode for aggregation proof generation");
            let (public_values, _) = self
                .prover
                .network_prover
                .execute(AGGREGATION_ELF, &sp1_stdin)
                .deferred_proof_verification(false)
                .run()?;

            SP1ProofWithPublicValues::create_mock_proof(
                &self.prover.agg_pk,
                public_values,
                SP1ProofMode::Groth16,
                SP1_CIRCUIT_VERSION,
            )
        } else {
            self.prover
                .network_prover
                .prove(&self.prover.agg_pk, &sp1_stdin)
                .groth16()
                .run_async()
                .await?
        };

        let transaction_request = self.rollup.proveProposal(proposal_id, agg_proof.bytes().into()).into_transaction_request();

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
    ) -> Result<U256> {
        tracing::info!("=== Proposal Creation Parameters ===");
        tracing::info!("Config values:");
        tracing::info!("  - Proposal interval: {:?} blocks", self.config.proposal_interval_in_blocks);
        tracing::info!("  - Fast finality mode: {:?}", self.config.fast_finality_mode);
        tracing::info!("  - Safe DB fallback: {:?}", self.config.safe_db_fallback);
        tracing::info!("  - Mock mode: {:?}", self.config.mock_mode);
        
        tracing::info!("Proposal parameters:");
        tracing::info!("  - L2 block number: {:?}", l2_block_number);
        tracing::info!("  - Prover address: {:?}", self.prover_address);
        tracing::info!("  - Rollup address: {:?}", self.rollup.address());

        let output_root = self.l2_provider.compute_output_root_at_block(l2_block_number).await?;
        tracing::info!("Output root: 0x{}", hex::encode(output_root));

        let transaction_request = self
            .rollup
            .submitProposal(output_root, l2_block_number.try_into().unwrap())
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
            .checked_add(U256::from(self.config.proposal_interval_in_blocks))
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
                let proposal_id = self.create_proposal(U256::from(next_l2_block_number)).await?;

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