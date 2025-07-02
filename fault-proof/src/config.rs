use std::env;

use alloy_primitives::Address;
use alloy_transport_http::reqwest::Url;
use anyhow::Result;

#[derive(Debug, Clone)]
pub struct RollupProposerConfig {
    /// The L1 RPC URL.
    pub l1_rpc: Url,

    /// The L2 RPC URL.
    pub l2_rpc: Url,

    /// The address of the rollup contract.
    pub rollup_address: Address,

    /// Whether to use mock mode.
    pub mock_mode: bool,

    /// Whether to use fast finality mode.
    pub fast_finality_mode: bool,

    /// The interval in seconds between checking for new proposals and game resolution.
    /// During each interval, the proposer:
    /// 1. Checks the safe L2 head block number
    /// 2. Gets the latest valid proposal
    /// 3. Creates a new game if conditions are met
    /// 4. Optionally attempts to resolve unchallenged games
    pub fetch_interval: u64,

    /// The number of proposals to check for defense.
    pub max_proposals_to_check_for_defense: u64,

    /// Whether to enable proposal resolution.
    /// When proposal resolution is not enabled, the proposer will only propose new proposals.
    pub enable_proposal_resolution: bool,

    /// The number of proposals to check for resolution.
    /// When proposal resolution is enabled, the proposer will attempt to resolve proposals that are
    /// unchallenged up to `max_proposals_to_check_for_resolution` proposals behind the latest proposal.
    pub max_proposals_to_check_for_resolution: u64,

    /// The maximum number of proposals to check for bond claiming.
    pub max_proposals_to_check_for_bond_claiming: u64,

    /// Whether to fallback to timestamp-based L1 head estimation even though SafeDB is not
    /// activated for op-node.
    pub safe_db_fallback: bool,

    /// The metrics port.
    pub metrics_port: u16,

    /// Maximum number of blocks per range proof.
    /// Splitting large ranges prevents hitting SP1's 16 MiB witness limit.
    pub range_proof_interval: u64,

    /// Cycle limit passed to SP1 when generating a range proof.
    pub cycle_limit: u64,
}

impl RollupProposerConfig {
    pub fn from_env() -> Result<Self> {
        let l1_rpc: Url = env::var("L1_RPC")?.parse().expect("L1_RPC not set");
        let l2_rpc: Url = env::var("L2_RPC")?.parse().expect("L2_RPC not set");
        let rollup_address: Address = env::var("ROLLUP_ADDRESS")?.parse().expect("ROLLUP_ADDRESS not set");
        let mock_mode: bool = env::var("MOCK_MODE").unwrap_or("false".to_string()).parse()?;
        let fast_finality_mode: bool = env::var("FAST_FINALITY_MODE")
            .unwrap_or("false".to_string())
            .parse()?;
        let proposal_interval_in_blocks: u64 = env::var("PROPOSAL_INTERVAL_IN_BLOCKS")
            .unwrap_or("1800".to_string())
            .parse()?;
        let fetch_interval: u64 = env::var("FETCH_INTERVAL").unwrap_or("30".to_string()).parse()?;
        let max_proposals_to_check_for_defense: u64 = env::var("MAX_PROPOSALS_TO_CHECK_FOR_DEFENSE")
            .unwrap_or("100".to_string())
            .parse()?;
        let enable_proposal_resolution: bool = env::var("ENABLE_PROPOSAL_RESOLUTION")
            .unwrap_or("true".to_string())
            .parse()?;
        let max_proposals_to_check_for_resolution: u64 = env::var("MAX_PROPOSALS_TO_CHECK_FOR_RESOLUTION")
            .unwrap_or("100".to_string())
            .parse()?;
        let max_proposals_to_check_for_bond_claiming: u64 = env::var("MAX_PROPOSALS_TO_CHECK_FOR_BOND_CLAIMING")
            .unwrap_or("100".to_string())
            .parse()?;
        let safe_db_fallback: bool = env::var("SAFE_DB_FALLBACK")
            .unwrap_or("false".to_string())
            .parse()?;
        let metrics_port: u16 = env::var("PROPOSER_METRICS_PORT")
            .unwrap_or("9000".to_string())
            .parse()?;
        let range_proof_interval: u64 = env::var("RANGE_PROOF_INTERVAL")
            .unwrap_or("512".to_string())
            .parse()?;
        let cycle_limit: u64 = env::var("SP1_CYCLE_LIMIT")
            .unwrap_or("100000000000".to_string())
            .parse()?;

        let config = Self {
            l1_rpc,
            l2_rpc,
            rollup_address,
            mock_mode,
            fast_finality_mode,
            fetch_interval,
            max_proposals_to_check_for_defense,
            enable_proposal_resolution,
            max_proposals_to_check_for_resolution,
            max_proposals_to_check_for_bond_claiming,
            safe_db_fallback,
            metrics_port,
            range_proof_interval,
            cycle_limit,
        };

        // Log all configuration values
        tracing::info!("Rollup Proposer Configuration:");
        tracing::info!("  L1 RPC: {}", config.l1_rpc);
        tracing::info!("  L2 RPC: {}", config.l2_rpc);
        tracing::info!("  Rollup Address: 0x{}", hex::encode(config.rollup_address));
        tracing::info!("  Mock Mode: {}", config.mock_mode);
        tracing::info!("  Fast Finality Mode: {}", config.fast_finality_mode);
        tracing::info!("  Fetch Interval (seconds): {}", config.fetch_interval);
        tracing::info!("  Max Proposals to Check for Defense: {}", config.max_proposals_to_check_for_defense);
        tracing::info!("  Enable Proposal Resolution: {}", config.enable_proposal_resolution);
        tracing::info!("  Max Proposals to Check for Resolution: {}", config.max_proposals_to_check_for_resolution);
        tracing::info!("  Max Proposals to Check for Bond Claiming: {}", config.max_proposals_to_check_for_bond_claiming);
        tracing::info!("  Safe DB Fallback: {}", config.safe_db_fallback);
        tracing::info!("  Metrics Port: {}", config.metrics_port);
        tracing::info!("  Range Proof Interval: {}", config.range_proof_interval);
        tracing::info!("  SP1 Cycle Limit: {}", config.cycle_limit);

        Ok(config)
    }
}

#[derive(Debug, Clone)]
pub struct ChallengerConfig {
    pub l1_rpc: Url,
    pub l2_rpc: Url,
    pub rollup_address: Address,

    /// The interval in seconds between checking for new challenges opportunities.
    pub fetch_interval: u64,


    /// The number of proposals to check for challenges.
    /// The challenger will check for challenges up to `max_proposals_to_check_for_challenge` proposals
    /// behind the latest proposal.
    pub max_proposals_to_check_for_challenge: u64,

    /// Whether to enable proposal resolution.
    /// When proposal resolution is not enabled, the challenger will only challenge proposals.
    pub enable_proposal_resolution: bool,

    /// The number of proposals to check for resolution.
    /// When proposal resolution is enabled, the challenger will attempt to resolve proposals that are
    /// challenged up to `max_proposals_to_check_for_resolution` proposals behind the latest proposal.
    pub max_proposals_to_check_for_resolution: u64,

    /// The maximum number of proposals to check for bond claiming.
    pub max_proposals_to_check_for_bond_claiming: u64,

    /// The metrics port.
    pub metrics_port: u16,

    /// Percentage (0.0-100.0) of valid games to challenge maliciously for testing.
    /// Set to 0.0 (default) for production use (honest challenging only).
    /// Set to >0.0 for testing defense mechanisms.
    pub malicious_challenge_percentage: f64,
}

impl ChallengerConfig {
    pub fn from_env() -> Result<Self> {
        Ok(Self {
            l1_rpc: env::var("L1_RPC")?.parse().expect("L1_RPC not set"),
            l2_rpc: env::var("L2_RPC")?.parse().expect("L2_RPC not set"),
            rollup_address: env::var("ROLLUP_ADDRESS")?.parse().expect("ROLLUP_ADDRESS not set"),
            fetch_interval: env::var("FETCH_INTERVAL").unwrap_or("30".to_string()).parse()?,
            max_proposals_to_check_for_challenge: env::var("MAX_PROPOSALS_TO_CHECK_FOR_CHALLENGE")
                .unwrap_or("100".to_string())
                .parse()?,
            enable_proposal_resolution: env::var("ENABLE_PROPOSAL_RESOLUTION")
                .unwrap_or("true".to_string())
                .parse()?,
            max_proposals_to_check_for_resolution: env::var("MAX_PROPOSALS_TO_CHECK_FOR_RESOLUTION")
                .unwrap_or("100".to_string())
                .parse()?,
            max_proposals_to_check_for_bond_claiming: env::var("MAX_PROPOSALS_TO_CHECK_FOR_BOND_CLAIMING")
                .unwrap_or("100".to_string())
                .parse()?,
            metrics_port: env::var("CHALLENGER_METRICS_PORT")
                .unwrap_or("9001".to_string())
                .parse()?,
            malicious_challenge_percentage: env::var("MALICIOUS_CHALLENGE_PERCENTAGE")
                .unwrap_or("0.0".to_string())
                .parse()?,
        })
    }
}
