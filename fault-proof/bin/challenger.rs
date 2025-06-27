use std::{env, sync::Arc, time::Duration};

use alloy_primitives::{Address, TxHash, U256};
use alloy_provider::{Provider, ProviderBuilder};
use alloy_transport_http::reqwest::Url;
use anyhow::Result;
use clap::Parser;
use fault_proof::{
    contract::Rollup::{self, RollupInstance},
    config::ChallengerConfig,
    prometheus::ChallengerGauge,
    utils::setup_logging,
    Action, L1Provider, L2Provider, L2ProviderTrait, Mode, RollupTrait,
};
use op_succinct_host_utils::metrics::{init_metrics, MetricsGauge};
use op_succinct_signer_utils::Signer;
use rand::Rng;
use tokio::time;

#[derive(Parser)]
struct Args {
    #[arg(long, default_value = ".env.challenger")]
    env_file: String,
}

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

    /// Check if a proposal claims a non-existent block
    async fn is_claiming_future_block(&self, l2_block_number: u128) -> Result<Option<u64>> {
        match self.l2_provider.get_l2_block_by_number(alloy_eips::BlockNumberOrTag::Latest).await {
            Ok(block) => {
                let current_max = block.header.number;
                if l2_block_number > current_max as u128 {
                    Ok(Some(current_max))
                } else {
                    Ok(None)
                }
            }
            Err(e) => Err(anyhow::anyhow!("Failed to get current max block height: {}", e))
        }
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

        // Find oldest challengable proposal
        let proposal_id = match self.rollup.get_oldest_challengable_proposal(
            self.config.max_proposals_to_check_for_challenge,
            self.l2_provider.clone(),
        ).await? {
            Some(id) => id,
            None => {
                tracing::debug!("No challengable proposals found");
                return Ok(());
            }
        };

        let proposal = self.rollup.getProposal(proposal_id).call().await?;

        // Handle malicious challenges for testing
        if self.config.malicious_challenge_percentage > 0.0 {
            let output_root = self.l2_provider
                .compute_output_root_at_block(U256::from(proposal.l2BlockNumber))
                .await;
            
            if let Ok(root) = output_root {
                if root == proposal.rootClaim {
                    let random_value: f64 = rand::rng().random::<f64>() * 100.0;
                    if random_value < self.config.malicious_challenge_percentage {
                        tracing::warn!(
                            "Maliciously challenging valid proposal {} for testing",
                            proposal_id
                        );
                        match self.challenge_proposal(proposal_id).await {
                            Ok(_) => ChallengerGauge::ProposalsChallenged.increment(1.0),
                            Err(e) => {
                                tracing::warn!("Failed to challenge proposal {}: {:?}", proposal_id, e);
                                ChallengerGauge::ProposalChallengeError.increment(1.0);
                            }
                        }
                        return Ok(());
                    }
                }
            }
        }

        // Challenge the proposal (we already know it's invalid from get_oldest_challengable_proposal)
        match self.challenge_proposal(proposal_id).await {
            Ok(_) => ChallengerGauge::ProposalsChallenged.increment(1.0),
            Err(e) => {
                // Special handling for future block errors
                let error_msg = e.to_string();
                if error_msg.contains("Failed to get L2 block by number") {
                    if let Some(current_max) = self.is_claiming_future_block(proposal.l2BlockNumber).await? {
                        tracing::info!(
                            "Challenging proposal {} with future L2 block {} (current max: {})",
                            proposal_id,
                            proposal.l2BlockNumber,
                            current_max
                        );
                        match self.challenge_proposal(proposal_id).await {
                            Ok(_) => ChallengerGauge::ProposalsChallenged.increment(1.0),
                            Err(e) => {
                                tracing::warn!("Failed to challenge proposal {}: {:?}", proposal_id, e);
                                ChallengerGauge::ProposalChallengeError.increment(1.0);
                            }
                        }
                    } else {
                        return Err(anyhow::anyhow!(
                            "L2 block {} not found but within current range. Possible data issue.",
                            proposal.l2BlockNumber
                        ));
                    }
                } else {
                    tracing::warn!("Failed to challenge proposal {}: {:?}", proposal_id, e);
                    ChallengerGauge::ProposalChallengeError.increment(1.0);
                }
            }
        }

        Ok(())
    }

    /// Handles claiming bonds from resolved proposals
    pub async fn handle_bond_claiming(&self) -> Result<Action> {
        let _span = tracing::info_span!("[[Claiming Bonds]]").entered();

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
        let anchor_proposal_id = U256::from(self.rollup.anchorProposalId().call().await?);
        let anchor_proposal = self.rollup.getProposal(anchor_proposal_id).call().await?;
        ChallengerGauge::AnchorProposalL2BlockNumber.set(anchor_proposal.l2BlockNumber as f64);

        // Get latest proposal
        let proposals_length = self.rollup.get_proposals_length().await?;
        if proposals_length > U256::ZERO {
            let latest_proposal_id = proposals_length - U256::from(1);
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

                    if self.config.enable_proposal_resolution {
                        if let Err(e) = self.rollup.resolve_proposals(
                            Mode::Challenger,
                            self.config.max_proposals_to_check_for_resolution,
                            self.signer.clone(),
                            self.config.l1_rpc.clone(),
                            self.l2_provider.clone(),
                        ).await {
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

#[tokio::main]
async fn main() -> Result<()> {
    // Install a default CryptoProvider once per process to satisfy rustls >=0.23.
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();

    setup_logging();

    let args = Args::parse();
    dotenv::from_filename(args.env_file).ok();

    let challenger_signer = Signer::from_env()?;

    let l1_provider =
        ProviderBuilder::new().connect_http(env::var("L1_RPC").unwrap().parse::<Url>().unwrap());

    let rollup = Rollup::new(
        env::var("ROLLUP_ADDRESS")
            .expect("ROLLUP_ADDRESS must be set")
            .parse::<Address>()
            .unwrap(),
        l1_provider.clone(),
    );

    let challenger = RollupChallenger::new(challenger_signer, rollup)
        .await
        .unwrap();

    // Initialize challenger gauges
    ChallengerGauge::register_all();

    // Initialize metrics exporter
    init_metrics(&challenger.config.metrics_port);

    // Initialize the metrics gauges
    ChallengerGauge::init_all();

    challenger.run().await.expect("Runs in an infinite loop");

    Ok(())
}