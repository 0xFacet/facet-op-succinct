pub mod config;
pub mod contract;
pub mod prometheus;
pub mod proposer;
pub mod utils;


use alloy_eips::BlockNumberOrTag;
use alloy_primitives::{address, keccak256, Address, FixedBytes, B256, U256};
use alloy_provider::{Provider, RootProvider};
use alloy_rpc_types_eth::Block;
use alloy_sol_types::{SolValue, sol};
use alloy_transport_http::reqwest::Url;
use anyhow::{bail, Result};
use async_trait::async_trait;
use op_alloy_network::Optimism;
use op_alloy_rpc_types::Transaction;
use op_succinct_signer_utils::Signer;

use crate::contract::Rollup::{RollupInstance, ProposalStatus};

pub type L1Provider = RootProvider;
pub type L2Provider = RootProvider<Optimism>;
pub type L2NodeProvider = RootProvider<Optimism>;

pub const NUM_CONFIRMATIONS: u64 = 3;
pub const TIMEOUT_SECONDS: u64 = 60;

#[derive(Debug, Clone, Copy)]
pub enum Mode {
    Proposer,
    Challenger,
}

#[derive(Debug)]
pub enum Action {
    Performed,
    Skipped,
}

#[async_trait]
pub trait L2ProviderTrait {
    /// Get the L2 block by number.
    async fn get_l2_block_by_number(
        &self,
        block_number: BlockNumberOrTag,
    ) -> Result<Block<Transaction>>;

    /// Get the L2 storage root for an address at a given block number.
    async fn get_l2_storage_root(
        &self,
        address: Address,
        block_number: BlockNumberOrTag,
    ) -> Result<B256>;

    /// Compute the output root at a given L2 block number.
    async fn compute_output_root_at_block(&self, l2_block_number: U256) -> Result<FixedBytes<32>>;
}

#[async_trait]
impl L2ProviderTrait for L2Provider {
    /// Get the L2 block by number.
    async fn get_l2_block_by_number(
        &self,
        block_number: BlockNumberOrTag,
    ) -> Result<Block<Transaction>> {
        let block = self.get_block_by_number(block_number).await?;
        if let Some(block) = block {
            Ok(block)
        } else {
            bail!("Failed to get L2 block by number");
        }
    }

    /// Get the L2 storage root for an address at a given block number.
    async fn get_l2_storage_root(
        &self,
        address: Address,
        block_number: BlockNumberOrTag,
    ) -> Result<B256> {
        let storage_root =
            self.get_proof(address, Vec::new()).block_id(block_number.into()).await?.storage_hash;
        Ok(storage_root)
    }

    /// Compute the output root at a given L2 block number.
    ///
    /// Local implementation is used because the RPC method `optimism_outputAtBlock` can fail for
    /// older blocks if the L2 node isn't fully synced or has pruned historical state data.
    ///
    /// Common error: "missing trie node ... state is not available".
    async fn compute_output_root_at_block(&self, l2_block_number: U256) -> Result<FixedBytes<32>> {
        let l2_block = self
            .get_l2_block_by_number(BlockNumberOrTag::Number(l2_block_number.to::<u64>()))
            .await?;
        let l2_state_root = l2_block.header.state_root;
        let l2_claim_hash = l2_block.header.hash;
        let l2_storage_root = self
            .get_l2_storage_root(
                address!("0x4200000000000000000000000000000000000016"),
                BlockNumberOrTag::Number(l2_block_number.to::<u64>()),
            )
            .await?;

        sol! {
            struct L2Output {
                uint32 zero;
                bytes32 l2_state_root;
                bytes32 l2_storage_hash;
                bytes32 l2_claim_hash;
            }
        }

        let l2_claim_encoded = L2Output {
            zero: 0,
            l2_state_root: l2_state_root.0.into(),
            l2_storage_hash: l2_storage_root.0.into(),
            l2_claim_hash: l2_claim_hash.0.into(),
        };
        let l2_output_root = keccak256(l2_claim_encoded.abi_encode());
        Ok(l2_output_root)
    }
}

#[async_trait]
pub trait RollupTrait<P>
where
    P: Provider + Clone,
{
    /// Get the latest proposal index
    async fn get_proposals_length(&self) -> Result<U256>;

    /// Get the latest valid proposal whose output root matches the true output root.
    /// Returns (l2_block_number, proposal_id) or None if no valid proposals exist.
    async fn get_latest_valid_proposal(
        &self,
        l2_provider: L2Provider,
    ) -> Result<Option<(U256, U256)>>;

    /// Get the oldest proposal with a given condition within a window.
    async fn get_oldest_proposal<S, O>(
        &self,
        max_proposals_to_check: u64,
        l2_provider: L2Provider,
        status_check: S,
        output_root_check: O,
        log_message: &str,
    ) -> Result<Option<U256>>
    where
        S: Fn(ProposalStatus) -> bool + Send + Sync,
        O: Fn(B256, B256) -> bool + Send + Sync;

    /// Get the oldest challengable proposal.
    async fn get_oldest_challengable_proposal(
        &self,
        max_proposals_to_check: u64,
        l2_provider: L2Provider,
    ) -> Result<Option<U256>>;

    /// Get the oldest defensible proposal (valid proposals that have been challenged).
    async fn get_oldest_defensible_proposal(
        &self,
        max_proposals_to_check: u64,
        l2_provider: L2Provider,
    ) -> Result<Option<U256>>;

    /// Check if we should attempt resolution based on parent proposal status.
    async fn should_attempt_resolution(&self, oldest_proposal_id: U256) -> Result<bool>;

    /// Try to resolve a single proposal.
    async fn try_resolve_proposal(
        &self,
        proposal_id: U256,
        mode: Mode,
        signer: Signer,
        l1_rpc: Url,
        l2_provider: L2Provider,
    ) -> Result<Action>;

    /// Resolve multiple proposals within a window.
    async fn resolve_proposals(
        &self,
        mode: Mode,
        max_proposals_to_check: u64,
        signer: Signer,
        l1_rpc: Url,
        l2_provider: L2Provider,
    ) -> Result<()>;
}

#[async_trait]
impl<P> RollupTrait<P> for RollupInstance<P>
where
    P: Provider + Clone,
{
    async fn get_proposals_length(&self) -> Result<U256> {
        Ok(self.getProposalsLength().call().await?)
    }

    async fn get_latest_valid_proposal(
        &self,
        l2_provider: L2Provider,
    ) -> Result<Option<(U256, U256)>> {
        let proposals_length = self.get_proposals_length().await?;
        if proposals_length == U256::ZERO {
            tracing::info!("No proposals exist yet");
            return Ok(None);
        }

        let mut proposal_id = proposals_length - U256::from(1);
        let mut block_number;

        loop {
            let proposal = self.getProposal(proposal_id).call().await?;
            block_number = U256::from(proposal.l2BlockNumber);
            
            tracing::debug!(
                "Checking if proposal {:?} at block {:?} is valid",
                proposal_id,
                block_number
            );

            let output_root = l2_provider.compute_output_root_at_block(block_number).await?;

            if output_root == proposal.rootClaim {
                break;
            }

            tracing::info!(
                "Output root {:?} is not same as proposal claim {:?}",
                output_root,
                proposal.rootClaim
            );

            if proposal_id == U256::ZERO {
                tracing::info!("No valid proposals found after checking all proposals");
                return Ok(None);
            }

            proposal_id -= U256::from(1);
        }

        tracing::info!(
            "Latest valid proposal at id {:?} with l2 block number: {:?}",
            proposal_id,
            block_number
        );

        Ok(Some((block_number, proposal_id)))
    }

    async fn get_oldest_proposal<S, O>(
        &self,
        max_proposals_to_check: u64,
        l2_provider: L2Provider,
        status_check: S,
        output_root_check: O,
        log_message: &str,
    ) -> Result<Option<U256>>
    where
        S: Fn(ProposalStatus) -> bool + Send + Sync,
        O: Fn(B256, B256) -> bool + Send + Sync,
    {
        let proposals_length = self.get_proposals_length().await?;
        if proposals_length == U256::ZERO {
            tracing::info!("No proposals exist yet");
            return Ok(None);
        }

        let anchor_id = U256::from(self.anchorProposalId().call().await?);
        let start_id = anchor_id + U256::from(1);
        let end_id = proposals_length.min(start_id + U256::from(max_proposals_to_check));

        tracing::info!(
            "Searching for {} - checking proposals from {} to {}",
            log_message,
            start_id,
            end_id - U256::from(1)
        );

        for proposal_id in start_id.to::<u64>()..end_id.to::<u64>() {
            let proposal_id = U256::from(proposal_id);
            let proposal = match self.getProposal(proposal_id).call().await {
                Ok(p) => p,
                Err(_) => continue,
            };

            let proposal_status = proposal.proposalStatus;

            if !status_check(proposal_status) {
                tracing::debug!(
                    "Proposal {} has status {:?}, does not match criteria",
                    proposal_id,
                    proposal_status
                );
                continue;
            }

            // Check if proposal deadline has NOT passed yet (for challenging/defending)
            // We can only challenge/defend proposals before the deadline
            let current_timestamp = l2_provider
                .get_l2_block_by_number(BlockNumberOrTag::Latest)
                .await?
                .header
                .timestamp;
            
            if proposal.deadline < current_timestamp {
                tracing::debug!(
                    "Proposal {} deadline {} has passed, cannot challenge/defend",
                    proposal_id,
                    proposal.deadline
                );
                continue;
            }

            let block_number = U256::from(proposal.l2BlockNumber);
            let output_root = match l2_provider.compute_output_root_at_block(block_number).await {
                Ok(root) => root,
                Err(e) => {
                    tracing::warn!("Failed to compute output root for proposal {}: {}", proposal_id, e);
                    continue;
                }
            };

            if output_root_check(output_root, proposal.rootClaim) {
                tracing::info!(
                    "{} {} at L2 block number: {}",
                    log_message,
                    proposal_id,
                    block_number
                );
                return Ok(Some(proposal_id));
            }
        }

        Ok(None)
    }

    async fn get_oldest_challengable_proposal(
        &self,
        max_proposals_to_check: u64,
        l2_provider: L2Provider,
    ) -> Result<Option<U256>> {
        self.get_oldest_proposal(
            max_proposals_to_check,
            l2_provider,
            |status| status == ProposalStatus::Unchallenged,
            |output_root, proposal_claim| output_root != proposal_claim,
            "Oldest challengable proposal",
        )
        .await
    }

    async fn get_oldest_defensible_proposal(
        &self,
        max_proposals_to_check: u64,
        l2_provider: L2Provider,
    ) -> Result<Option<U256>> {
        self.get_oldest_proposal(
            max_proposals_to_check,
            l2_provider,
            |status| status == ProposalStatus::Challenged,
            |output_root, proposal_claim| output_root == proposal_claim,
            "Oldest defensible proposal",
        )
        .await
    }

    async fn should_attempt_resolution(&self, oldest_proposal_id: U256) -> Result<bool> {
        let proposal = self.getProposal(oldest_proposal_id).call().await?;
        
        // Always attempt resolution for first proposals (those with parent_index == u32::MAX)
        if proposal.parentIndex == u32::MAX {
            Ok(true)
        } else {
            // For other proposals, only attempt if parent is resolved
            let parent_proposal = self.getProposal(U256::from(proposal.parentIndex)).call().await?;
            let parent_status = parent_proposal.proposalStatus;
            Ok(parent_status == ProposalStatus::Resolved)
        }
    }

    async fn try_resolve_proposal(
        &self,
        proposal_id: U256,
        mode: Mode,
        signer: Signer,
        l1_rpc: Url,
        _l2_provider: L2Provider,
    ) -> Result<Action> {
        // Check if proposal is resolvable
        let is_resolvable = match self.isResolvable(proposal_id).call().await {
            Ok(resolvable) => resolvable,
            Err(_) => return Ok(Action::Skipped),
        };
        
        if !is_resolvable {
            return Ok(Action::Skipped);
        }

        let proposal = self.getProposal(proposal_id).call().await?;
        let proposal_status = proposal.proposalStatus;

        match mode {
            Mode::Proposer => {
                if proposal_status != ProposalStatus::Unchallenged {
                    tracing::debug!(
                        "Proposal {} is not unchallenged, skipping resolution",
                        proposal_id
                    );
                    return Ok(Action::Skipped);
                }
            }
            Mode::Challenger => {
                if proposal_status != ProposalStatus::Challenged {
                    tracing::debug!(
                        "Proposal {} is not challenged, skipping resolution",
                        proposal_id
                    );
                    return Ok(Action::Skipped);
                }

                // Verify we challenged this proposal
                if proposal.challenger != signer.address() {
                    tracing::debug!(
                        "Proposal {} was not challenged by us, skipping",
                        proposal_id
                    );
                    return Ok(Action::Skipped);
                }
            }
        }

        let transaction_request = self.resolveProposal(proposal_id).into_transaction_request();
        let receipt = signer.send_transaction_request(l1_rpc, transaction_request).await?;
        
        tracing::info!(
            "\x1b[1mSuccessfully resolved proposal {} with tx {:?}\x1b[0m",
            proposal_id,
            receipt.transaction_hash
        );
        
        Ok(Action::Performed)
    }

    async fn resolve_proposals(
        &self,
        mode: Mode,
        max_proposals_to_check: u64,
        signer: Signer,
        l1_rpc: Url,
        l2_provider: L2Provider,
    ) -> Result<()> {
        let proposals_length = self.get_proposals_length().await?;
        if proposals_length == U256::ZERO {
            tracing::info!("No proposals exist, skipping resolution");
            return Ok(());
        }

        let anchor_id = U256::from(self.anchorProposalId().call().await?);
        let start_id = anchor_id + U256::from(1);
        let end_id = proposals_length.min(start_id + U256::from(max_proposals_to_check));

        // Check if we should attempt resolution based on oldest proposal
        if start_id < end_id && !self.should_attempt_resolution(start_id).await? {
            tracing::info!(
                "Oldest proposal {} has unresolved parent, skipping resolution",
                start_id
            );
            return Ok(());
        }

        for proposal_id in start_id.to::<u64>()..end_id.to::<u64>() {
            let proposal_id = U256::from(proposal_id);
            match self
                .try_resolve_proposal(
                    proposal_id,
                    mode,
                    signer.clone(),
                    l1_rpc.clone(),
                    l2_provider.clone(),
                )
                .await
            {
                Ok(Action::Performed) => {
                    use op_succinct_host_utils::metrics::MetricsGauge;
                    prometheus::ProposerGauge::ProposalsResolved.increment(1.0);
                }
                Ok(Action::Skipped) => {}
                Err(e) => {
                    tracing::debug!("Failed to resolve proposal {}: {:?}", proposal_id, e);
                }
            }
        }

        Ok(())
    }
}