use op_succinct_host_utils::metrics::MetricsGauge;
use strum::EnumMessage;
use strum_macros::{Display, EnumIter};

// Define an enum for all fault proof proposer metrics gauges.
#[derive(Debug, Clone, Copy, Display, EnumIter, EnumMessage)]
pub enum ProposerGauge {
    // Proposer metrics
    #[strum(
        serialize = "op_succinct_fp_finalized_l2_block_number",
        message = "Finalized L2 block number"
    )]
    FinalizedL2BlockNumber,
    #[strum(
        serialize = "op_succinct_fp_latest_proposal_l2_block_number",
        message = "Latest proposal L2 block number"
    )]
    LatestProposalL2BlockNumber,
    #[strum(
        serialize = "op_succinct_fp_anchor_proposal_l2_block_number",
        message = "Anchor proposal L2 block number"
    )]
    AnchorProposalL2BlockNumber,
    #[strum(
        serialize = "op_succinct_fp_proposals_created",
        message = "Total number of proposals created by the proposer"
    )]
    ProposalsCreated,
    #[strum(
        serialize = "op_succinct_fp_proposals_resolved",
        message = "Total number of proposals resolved by the proposer"
    )]
    ProposalsResolved,
    #[strum(
        serialize = "op_succinct_fp_bonds_claimed",
        message = "Total number of bonds claimed by the proposer"
    )]
    BondsClaimed,
    // Error metrics
    #[strum(
        serialize = "op_succinct_fp_proposal_creation_error",
        message = "Total number of proposal creation errors encountered by the proposer"
    )]
    ProposalCreationError,
    #[strum(
        serialize = "op_succinct_fp_proposal_defense_error",
        message = "Total number of proposal defense errors encountered by the proposer"
    )]
    ProposalDefenseError,
    #[strum(
        serialize = "op_succinct_fp_proposal_resolution_error",
        message = "Total number of proposal resolution errors encountered by the proposer"
    )]
    ProposalResolutionError,
    #[strum(
        serialize = "op_succinct_fp_bond_claiming_error",
        message = "Total number of bond claiming errors encountered by the proposer"
    )]
    BondClaimingError,
    #[strum(
        serialize = "op_succinct_fp_metrics_error",
        message = "Total number of metrics errors encountered by the proposer"
    )]
    MetricsError,
}

impl MetricsGauge for ProposerGauge {}

// Define an enum for all fault proof challenger metrics gauges.
#[derive(Debug, Clone, Copy, Display, EnumIter, EnumMessage)]
pub enum ChallengerGauge {
    // Challenger metrics
    #[strum(
        serialize = "op_succinct_fp_challenger_proposals_challenged",
        message = "Total number of proposals challenged by the challenger"
    )]
    ProposalsChallenged,
    #[strum(
        serialize = "op_succinct_fp_challenger_proposals_resolved",
        message = "Total number of proposals resolved by the challenger"
    )]
    ProposalsResolved,
    #[strum(
        serialize = "op_succinct_fp_challenger_bonds_claimed",
        message = "Total number of bonds claimed by the challenger"
    )]
    BondsClaimed,
    // Error metrics
    #[strum(
        serialize = "op_succinct_fp_challenger_proposal_challenging_error",
        message = "Total number of proposal challenging errors encountered by the challenger"
    )]
    ProposalChallengeError,
    #[strum(
        serialize = "op_succinct_fp_challenger_proposal_resolution_error",
        message = "Total number of proposal resolution errors encountered by the challenger"
    )]
    ProposalResolutionError,
    #[strum(
        serialize = "op_succinct_fp_challenger_bond_claiming_error",
        message = "Total number of bond claiming errors encountered by the challenger"
    )]
    BondClaimingError,
    #[strum(
        serialize = "op_succinct_fp_challenger_latest_proposal_l2_block_number",
        message = "Latest proposal L2 block number"
    )]
    LatestProposalL2BlockNumber,
    #[strum(
        serialize = "op_succinct_fp_challenger_anchor_proposal_l2_block_number",
        message = "Anchor proposal L2 block number"
    )]
    AnchorProposalL2BlockNumber,
    #[strum(
        serialize = "op_succinct_fp_challenger_metrics_error",
        message = "Total number of metrics errors encountered by the challenger"
    )]
    MetricsError,
}

impl MetricsGauge for ChallengerGauge {}
