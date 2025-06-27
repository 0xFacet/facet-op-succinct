use std::{convert::TryFrom, sync::Arc, time::Duration};

use alloy_primitives::{TxHash, U256};
use alloy_provider::{Provider, ProviderBuilder};
use anyhow::Result;
use op_succinct_signer_utils::Signer;
use rand::Rng;
use tokio::time;
use tracing;

use crate::{
    rollup_config::ChallengerConfig,
    rollup_contract::Rollup::{RollupInstance, ProposalStatus},
    rollup_prometheus::ChallengerGauge,
    Action, L1Provider, L2Provider, L2ProviderTrait,
};
use op_succinct_host_utils::metrics::MetricsGauge;

pub struct RollupChallenger<P>
where
    P: Provider + Clone + Send + Sync,
{
    pub config: ChallengerConfig,
    pub signer: Signer,
    pub l1_provider: L1Provider,
    pub l2_provider: L2Provider,
    pub rollup: Arc<RollupInstance<P>>,
    pub challenger_bond: U256,
}

impl<P> RollupChallenger<P>
where
    P: Provider + Clone + Send + Sync,
{
    /// Creates a new challenger instance for the Rollup contract
    pub async fn new(
        signer: Signer,
        rollup: RollupInstance<P>,
    ) -> Result<Self> {
        let config = ChallengerConfig::from_env()?;

        // Fetch bond constant from contract
        let challenger_bond = rollup.CHALLENGER_BOND().call().await?;

        Ok(Self {
            config: config.clone(),
            signer,
            l1_provider: ProviderBuilder::default().connect_http(config.l1_rpc.clone()),
            l2_provider: ProviderBuilder::default().connect_http(config.l2_rpc),
            rollup: Arc::new(rollup),
            challenger_bond,
        })
    }

    /// Challenges a proposal with an invalid output root
    pub async fn challenge_proposal(&self, proposal_id: U256) -> Result<TxHash> {
        tracing::info!("Challenging proposal {}", proposal_id);

        let transaction_request = self
            .rollup
            .challengeProposal(proposal_id)
            .value(self.challenger_bond)
            .into_transaction_request();

        let receipt = self
            .signer
            .send_transaction_request(self.config.l1_rpc.clone(), transaction_request)
            .await?;

        tracing::info!(
            "\x1b[1mSuccessfully challenged proposal {} with tx {:?}\x1b[0m",
            proposal_id,
            receipt.transaction_hash
        );

        Ok(receipt.transaction_hash)
    }

    /// Handles challenging invalid proposals
    pub async fn handle_proposal_challenges(&self) -> Result<()> {
        let _span = tracing::info_span!("[[Challenging]]").entered();

        let mut proposals_to_check = Vec::new();
        let anchor_id = U256::from(self.rollup.anchorProposalId().call().await?);
        
        tracing::debug!("Checking proposals starting from anchor proposal {}", anchor_id);
        
        // Check a reasonable range of proposals
        for i in 0..self.config.max_games_to_check_for_challenge {
            let proposal_id = anchor_id + U256::from(i) + U256::from(1);
            match self.rollup.getProposal(proposal_id).call().await {
                Ok(_) => proposals_to_check.push(proposal_id),
                Err(_) => break, // No more proposals
            }
        }

        tracing::debug!("Found {} proposals to check", proposals_to_check.len());

        for proposal_id in proposals_to_check {
            if proposal_id == U256::ZERO {
                continue; // Skip empty entries
            }

            let proposal = self.rollup.getProposal(proposal_id).call().await?;
            
            tracing::debug!(
                "Checking proposal {}: status={:?}, l2_block={}, root_claim={:?}",
                proposal_id,
                proposal.proposalStatus,
                proposal.l2BlockNumber,
                proposal.rootClaim
            );
            
            // Only challenge proposals that are unchallenged
            // proposalStatus is field 7, which is a u8 that needs to be converted
            let proposal_status = ProposalStatus::try_from(proposal.proposalStatus).unwrap_or(ProposalStatus::Resolved);
            if proposal_status != ProposalStatus::Unchallenged {
                continue;
            }

            // Compute the actual output root at the proposed L2 block
            let output_root = match self.l2_provider.compute_output_root_at_block(U256::from(proposal.l2BlockNumber)).await {
                Ok(root) => root,
                Err(e) => {
                    let error_msg = e.to_string();
                    
                    // Only handle the specific "block doesn't exist" error
                    if error_msg.contains("Failed to get L2 block by number") {
                        // Get the current max block height to verify this is actually an invalid proposal
                        let current_max_block = match self.l2_provider.get_l2_block_by_number(alloy_eips::BlockNumberOrTag::Latest).await {
                            Ok(block) => block.header.number,
                            Err(_) => {
                                // If we can't get the latest block, this is a system issue - fail
                                tracing::error!("Failed to get current max block height");
                                return Err(anyhow::anyhow!("Failed to get current max block height"));
                            }
                        };
                        
                        if proposal.l2BlockNumber > current_max_block as u128 {
                            tracing::warn!(
                                "Proposal {} claims L2 block {} which is beyond current max block {}",
                                proposal_id,
                                proposal.l2BlockNumber,
                                current_max_block
                            );
                            // The proposal claims a block that doesn't exist - challenge it
                            tracing::info!(
                                "Challenging proposal {} with future L2 block {} (max: {})",
                                proposal_id,
                                proposal.l2BlockNumber,
                                current_max_block
                            );
                            match self.challenge_proposal(proposal_id).await {
                                Ok(_) => {
                                    ChallengerGauge::ProposalsChallenged.increment(1.0);
                                }
                                Err(e) => {
                                    tracing::warn!("Failed to challenge proposal {}: {:?}", proposal_id, e);
                                    ChallengerGauge::ProposalChallengeError.increment(1.0);
                                }
                            }
                            continue; // Move to next proposal
                        } else {
                            // The block number is within range but still not found - this is suspicious
                            // and indicates a serious issue with the L2 node or data availability
                            tracing::error!(
                                "L2 block {} for proposal {} not found but is within current range (max: {}). This indicates a serious issue.",
                                proposal.l2BlockNumber,
                                proposal_id,
                                current_max_block
                            );
                            return Err(anyhow::anyhow!(
                                "L2 block {} not found but within range (max: {}). Possible data availability issue.",
                                proposal.l2BlockNumber,
                                current_max_block
                            ));
                        }
                    } else {
                        // For all other errors, fail immediately - let the challenger retry
                        tracing::error!(
                            "Unexpected error computing output root for proposal {} at L2 block {}: {:?}",
                            proposal_id,
                            proposal.l2BlockNumber,
                            error_msg
                        );
                        return Err(anyhow::anyhow!("Failed to compute output root: {}", error_msg));
                    }
                }
            };
            
            let should_challenge = if output_root != proposal.rootClaim {
                // Invalid proposal, always challenge
                tracing::info!(
                    "Found invalid proposal {} - computed root: {:?}, claimed root: {:?}",
                    proposal_id,
                    output_root,
                    proposal.rootClaim
                );
                true
            } else if self.config.malicious_challenge_percentage > 0.0 {
                // For testing: maliciously challenge some valid proposals
                let mut rng = rand::rng();
                let random_value: f64 = rng.random::<f64>() * 100.0;
                if random_value < self.config.malicious_challenge_percentage {
                    tracing::warn!(
                        "Maliciously challenging valid proposal {} for testing ({}% chance)",
                        proposal_id,
                        self.config.malicious_challenge_percentage
                    );
                    true
                } else {
                    false
                }
            } else {
                false
            };

            if should_challenge {
                match self.challenge_proposal(proposal_id).await {
                    Ok(_) => {
                        ChallengerGauge::ProposalsChallenged.increment(1.0);
                    }
                    Err(e) => {
                        tracing::warn!("Failed to challenge proposal {}: {:?}", proposal_id, e);
                        ChallengerGauge::ProposalChallengeError.increment(1.0);
                    }
                }
            }
        }

        Ok(())
    }

    /// Handles the resolution of challenged proposals
    pub async fn handle_proposal_resolution(&self) -> Result<()> {
        let _span = tracing::info_span!("[[Resolving]]").entered();

        // Get proposals to check for resolution
        let mut proposals_to_check = Vec::new();
        let anchor_id = U256::from(self.rollup.anchorProposalId().call().await?);
        
        for i in 0..self.config.max_games_to_check_for_resolution {
            let proposal_id = anchor_id + U256::from(i) + U256::from(1);
            match self.rollup.getProposal(proposal_id).call().await {
                Ok(_) => proposals_to_check.push(proposal_id),
                Err(_) => break,
            }
        }

        for proposal_id in proposals_to_check {
            if proposal_id == U256::ZERO {
                continue; // Skip empty entries
            }

            let proposal = self.rollup.getProposal(proposal_id).call().await?;
            
            // Only try to resolve challenged proposals that we challenged
            let proposal_status = ProposalStatus::try_from(proposal.proposalStatus).unwrap_or(ProposalStatus::Resolved);
            if proposal_status == ProposalStatus::Resolved || proposal.challenger != self.signer.address() {
                continue;
            }
            
            // Check if game is over
            let game_over = match self.rollup.gameOver(proposal_id).call().await {
                Ok(over) => over,
                Err(_) => continue,
            };
            
            if !game_over {
                continue;
            }

            // Check if we can resolve this proposal
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
                    ChallengerGauge::ProposalsResolved.increment(1.0);
                }
                Err(e) => {
                    tracing::debug!("Could not resolve proposal {}: {:?}", proposal_id, e);
                }
            }
        }

        Ok(())
    }

    /// Handles claiming bonds from resolved proposals
    pub async fn handle_bond_claiming(&self) -> Result<Action> {
        let _span = tracing::info_span!("[[Claiming Bonds]]").entered();

        // Check if we have any credit to claim
        let credit = self.rollup.credit(self.signer.address()).call().await?;
        
        if credit == U256::ZERO {
            tracing::info!("No credit to claim");
            return Ok(Action::Skipped);
        }

        tracing::info!("Attempting to claim credit: {} wei", credit);

        let transaction_request = self.rollup.claimCredit(self.signer.address()).into_transaction_request();

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
                ChallengerGauge::BondsClaimed.increment(1.0);
                Ok(Action::Performed)
            }
            Err(e) => Err(anyhow::anyhow!("Failed to claim credit: {:?}", e)),
        }
    }

    /// Fetch the challenger metrics
    async fn fetch_challenger_metrics(&self) -> Result<()> {
        // Get the anchor proposal
        let anchor_proposal_id = U256::from(self.rollup.anchorProposalId().call().await?);
        let anchor_proposal = self.rollup.getProposal(anchor_proposal_id).call().await?;

        // Update metrics for anchor L2 block number
        ChallengerGauge::AnchorProposalL2BlockNumber.set(anchor_proposal.l2BlockNumber as f64);

        // Update metrics for latest proposal
        let mut latest_proposal_id = anchor_proposal_id;
        loop {
            if self.rollup.getProposal(latest_proposal_id + U256::from(1)).call().await.is_err() {
                break;
            }
            latest_proposal_id += U256::from(1);
        }
        
        if latest_proposal_id > U256::ZERO {
            let latest_proposal = self.rollup.getProposal(latest_proposal_id).call().await?;
            ChallengerGauge::LatestProposalL2BlockNumber.set(latest_proposal.l2BlockNumber as f64);
        }

        Ok(())
    }

    /// Runs the challenger indefinitely
    pub async fn run(&self) -> Result<()> {
        tracing::info!("Rollup Challenger running...");
        let mut interval = time::interval(Duration::from_secs(self.config.fetch_interval));
        let mut metrics_interval = time::interval(Duration::from_secs(15));

        loop {
            tokio::select! {
                _ = interval.tick() => {
                    if let Err(e) = self.handle_proposal_challenges().await {
                        tracing::warn!("Failed to handle proposal challenges: {:?}", e);
                        ChallengerGauge::ProposalChallengeError.increment(1.0);
                    }

                    if self.config.enable_game_resolution {
                        if let Err(e) = self.handle_proposal_resolution().await {
                            tracing::warn!("Failed to handle proposal resolution: {:?}", e);
                            ChallengerGauge::ProposalResolutionError.increment(1.0);
                        }
                    }

                    match self.handle_bond_claiming().await {
                        Ok(Action::Performed) => {
                            ChallengerGauge::BondsClaimed.increment(1.0);
                        }
                        Ok(Action::Skipped) => {}
                        Err(e) => {
                            tracing::warn!("Failed to handle bond claiming: {:?}", e);
                            ChallengerGauge::BondClaimingError.increment(1.0);
                        }
                    }
                }
                _ = metrics_interval.tick() => {
                    if let Err(e) = self.fetch_challenger_metrics().await {
                        tracing::warn!("Failed to fetch metrics: {:?}", e);
                        ChallengerGauge::MetricsError.increment(1.0);
                    }
                }
            }
        }
    }
}