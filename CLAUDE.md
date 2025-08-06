# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is OP Succinct?

OP Succinct is a zkEVM proving system for OP Stack rollups that replaces the traditional 7-day fraud proof window with ZK proofs. It enables near-instant finality by proving the correctness of L2 state transitions using SP1, a performant zkVM.

## Architecture Overview

The system implements a dual-track rollup architecture combining the benefits of optimistic rollups (low cost) with validity rollups (instant finality):

- **Fault Proof Track**: Traditional optimistic flow where proposals can be challenged and defended with proofs
- **Validity Proof Track**: Direct ZK proof submission that bypasses challenge periods entirely

This hybrid approach allows users to choose between cost efficiency and finality speed based on their needs.

### Key Architectural Features

- **Canonical Proposal System**: Maps L2 block numbers to canonical proposals with O(1) lookups
- **Bulk Invalidation**: When validity proofs are submitted, all conflicting fault proof proposals are automatically invalidated
- **L1 Block Hash Checkpointing**: System for storing L1 block hashes required for proof verification
- **Training Wheels**: Optional safety features including fallback timeout for censorship resistance
- **Multi-DA Support**: Compatible with both Ethereum and Celestia data availability layers

## Core Components

### 1. Rollup.sol Contract (`contracts/src/`)
The central smart contract deployed on L1 that manages the entire system:

**Core Functionality:**
- Accepts proposals (L2 state root claims) from whitelisted proposers
- Enforces a challenge mechanism where anyone can dispute incorrect proposals
- Verifies ZK proofs using the SP1 verifier to resolve disputes
- Manages bond economics - both proposers and challengers stake ETH
- Maintains an "anchor" that tracks the latest proven L2 state
- Supports direct validity proofs via `proveBlock()` for instant finality
- Implements bulk invalidation to handle conflicts between proof tracks

**Advanced Features:**
- **Proposal Status Machine**: 5 states (Unchallenged, Challenged, UnchallengedAndProven, ChallengedAndProven, Resolved)
- **Cascading Invalidity**: Invalid parent proposals automatically invalidate all descendants
- **L1 Checkpoint Storage**: Stores L1 block hashes for proof verification
- **Fallback Proposer**: After `FALLBACK_TIMEOUT_SECS`, anyone can propose to prevent censorship
- **Canonical Proposals**: Direct mapping from L2 block numbers to canonical output roots

### 2. Fault Proof Services

#### Proposer Service (`fault-proof/src/proposer.rs`)
An automated service that monitors L2 and submits proposals:

**Features:**
- Watches for finalized L2 blocks at regular intervals
- Computes output roots (commitments to L2 state) 
- Submits proposals to Rollup.sol with required bonds
- Defends challenged proposals by generating ZK proofs
- Orchestrates proof generation across multiple chunks
- Claims bonds after successful resolutions
- **Fast Finality Mode**: Option to immediately generate proofs after proposing
- **Prometheus Metrics**: Comprehensive monitoring of proposal activities

**Proof Generation Orchestration:**
- Splits large block ranges into manageable chunks
- Generates range proofs for each chunk in parallel
- Aggregates all proofs into a single proof for on-chain submission

#### Challenger Service (`fault-proof/src/challenger.rs`)
Monitors and validates all proposals to ensure correctness:

**Features:**
- Independently computes expected output roots
- Challenges proposals with incorrect roots
- Challenges proposals claiming future blocks  
- Claims bonds from successful challenges
- **Test Mode**: Support for malicious challenges in development
- **Prometheus Metrics**: Monitoring of challenge activities

### 3. Bridge Contracts
Demonstrates integration with the rollup for asset transfers:

#### L1Bridge (`contracts/src/L1Bridge.sol`)
Handles L1-side of withdrawals with training wheels:
- **Root Blacklisting**: Owner can invalidate compromised roots
- **Withdrawal Delays**: Additional time buffer for security
- **Pause Functionality**: Emergency stop mechanism
- **Rollup Reference Updates**: Can point to new rollup for fork support

#### L2Bridge (`contracts/src/L2Bridge.sol`)
Manages L2 wrapped tokens:
- Standard ERC20 wrapped token deployment
- Deposit/withdrawal message handling
- Integration with L2 messaging system

### 4. Web Application (`web/`)
Next.js application for user-friendly bridge interaction:
- **Deposit Wizard**: Step-by-step L1 to L2 transfers
- **Withdrawal Wizard**: Guided L2 to L1 withdrawals with status tracking
- **Proposal Monitoring**: Real-time tracking of proposal states
- **Proof Building**: Automated withdrawal proof generation
- **Viem/Wagmi Integration**: Modern Web3 stack

## Proof Generation Architecture

### Range Programs
Two implementations for different data availability layers:

#### Ethereum Range Program (`programs/range/`)
The core zkVM program that proves L2 state transitions using Ethereum DA:
- Executes a range of L2 blocks inside the zkVM
- Verifies all state transitions are valid
- Fetches data from Ethereum L1
- Outputs proof containing:
  - `l2PreRoot`: State root before the range
  - `l2PostRoot`: State root after execution  
  - `l1Head`: L1 block hash for data availability
  - `rollupConfigHash`: Ensures correct chain configuration

#### Celestia Range Program (`programs/celestia-range/`)
Alternative implementation using Celestia for data availability:
- Same state transition verification
- Fetches data from Celestia instead of Ethereum
- Supports Celestia-specific data verification
- Compatible with same aggregation layer

### Aggregation Program (`programs/aggregation/`)
Combines multiple range proofs for efficiency:
- Takes multiple sequential range proofs
- Verifies they form a continuous chain
- Produces a single aggregated proof for on-chain verification
- Reduces on-chain verification costs
- Works with both Ethereum and Celestia range proofs

## Key Flows

### Fault Proof Flow (Optimistic Path)
1. Proposer monitors L2 for finalized blocks
2. Every `PROPOSAL_INTERVAL` blocks, computes the output root
3. Submits proposal to Rollup.sol with `PROPOSER_BOND`
4. Proposal enters challenge window (`MAX_CHALLENGE_SECS`)
5. If unchallenged, resolves as valid after timeout
6. Anchor advances if proposal follows canonical chain
7. Bond returned to proposer

### Validity Proof Flow (Direct ZK Path)
1. Anyone calls `proveBlock()` with:
   - L2 block number (must be `anchor + PROPOSAL_INTERVAL`)
   - Output root claim for that block
   - ZK proof of state transition from anchor
2. Contract verifies proof immediately using SP1 verifier
3. Block becomes canonical instantly (no challenge period)
4. Any conflicting fault proof proposals are bulk invalidated
5. Anchor advances immediately
6. No bonds required for validity proofs

### Challenge/Defense Flow
1. Challenger detects invalid proposal (wrong root or future block)
2. Submits challenge with `CHALLENGER_BOND`
3. Starts proof countdown (`MAX_PROVE_SECS`)
4. Proposer generates defense proof:
   - Splits block range into manageable chunks
   - Generates range proof for each chunk using SP1
   - Aggregates all proofs into single proof
5. Submits aggregated proof on-chain
6. Contract verifies proof to determine winner
7. If proposer fails to submit proof, challenger wins

### Resolution Flow
1. After deadline passes, anyone can call `resolveProposal()`
2. Resolution follows strict hierarchy:
   - If parent proposal invalid → challenger wins (cascading invalidity)
   - If conflicts with canonical → challenger wins (bulk invalidation)
   - If has valid proof → defender wins
   - If challenged but no proof → challenger wins
   - If unchallenged → defender wins
3. Valid proposals may advance the anchor
4. Bonds distributed to winners (burned if no valid recipient)

### Withdrawal Flow
1. User initiates withdrawal on L2 (creates MessagePassed event)
2. Wait for L2 block containing withdrawal to be finalized
3. Wait for proposal containing that L2 block
4. Generate merkle proof of withdrawal against proposal's output root
5. Submit proof to L1Bridge contract
6. Wait for additional withdrawal delay (if configured)
7. Finalize withdrawal to receive funds

## Build System and Dependencies

### SP1 Integration
- Uses SP1 zkVM version 5.1.0
- Custom circuit configurations for optimal performance
- Automated ELF building for range and aggregation programs

### Dependency Management
- Custom patches for Kona, REVM, and OP-Alloy
- Toggle script (`toggle-deps.sh`) for switching between GitHub and local dependencies
- Support for both remote and local development workflows

### ELF Management
- Automated binary building for zkVM programs
- Embedded ELFs in Rust code for easy deployment
- Version tracking for compatibility

## Configuration and Deployment

### Environment Configuration
Network-specific configuration files:
- `.env.sepolia`: Sepolia testnet configuration
- `.env.mainnet`: Mainnet configuration
- `.env.local`: Local development configuration

### Key Configuration Parameters
```bash
# Rollup Configuration
PROPOSAL_INTERVAL=1800          # L2 blocks between proposals
MAX_CHALLENGE_SECS=3600         # Challenge window duration
MAX_PROVE_SECS=7200            # Proof submission deadline
PROPOSER_BOND=0.1              # ETH bond for proposals
CHALLENGER_BOND=0.1            # ETH bond for challenges
FALLBACK_TIMEOUT_SECS=86400    # When anyone can propose

# Service Configuration
FAST_FINALITY=false            # Generate proofs immediately
RPC_POLL_INTERVAL=10           # Seconds between RPC polls
```

### Deployment Scripts
- `DeployRollup.s.sol`: Main rollup contract deployment
- `DeployBridges.s.sol`: Bridge contracts deployment
- `DeployOPSuccinctL2OutputOracle.s.sol`: Oracle deployment
- `UpgradeOPSuccinctL2OutputOracle.s.sol`: Oracle upgrades
- `AddRollupConfig.s.sol`: Add new rollup configurations
- `RemoveRollupConfig.s.sol`: Remove rollup configurations

## Development Commands

### Core Commands
```bash
# Run tests
cargo test --release
forge test

# Build programs
just build-elf                  # Build all zkVM programs
just build-range-elf           # Build range program only
just build-aggregation-elf     # Build aggregation program only

# Run services
just run-proposer              # Start proposer service
just run-challenger            # Start challenger service

# Generate proofs
just run-single <l2_block> prove=true  # Generate proof for single block
just cost-estimator <start> <end>      # Estimate proof costs for range
```

### Deployment Commands
```bash
# Deploy contracts
just deploy-rollup-sepolia     # Deploy to Sepolia
just deploy-rollup-mainnet     # Deploy to mainnet
just deploy-bridges-sepolia    # Deploy bridges to Sepolia

# Configuration management
just add-rollup-config <name>  # Add new rollup configuration
just remove-rollup-config <id> # Remove rollup configuration

# Oracle management
just deploy-oracle             # Deploy L2 output oracle
just upgrade-oracle            # Upgrade oracle implementation
```

### Development Helpers
```bash
# Get starting values
just get-starting-root         # Get initial L2 root
just get-starting-timestamp    # Get initial timestamp

# Docker operations
just start-docker              # Start all services in Docker
just stop-docker               # Stop Docker services

# Dependency management
./toggle-deps.sh               # Toggle between GitHub/local deps
```

## Monitoring and Metrics

### Prometheus Metrics
Both proposer and challenger expose metrics on port 6060:

**Proposer Metrics:**
- `proposals_submitted`: Total proposals submitted
- `proposals_defended`: Successful defenses
- `bonds_claimed`: Total bonds claimed
- `proof_generation_time`: Time to generate proofs
- `proof_generation_cycles`: SP1 cycles used

**Challenger Metrics:**
- `challenges_submitted`: Total challenges made
- `challenges_won`: Successful challenges
- `invalid_proposals_detected`: Count of invalid proposals
- `monitoring_errors`: Service errors

### Grafana Dashboards
Pre-configured dashboards available for:
- Proposal activity monitoring
- Proof generation performance
- Bond economics tracking
- Error rate monitoring

## Security Considerations

### Core Security Features
1. **Proof Verification**: All proofs verified on-chain using SP1 verifier
2. **Time Delays**: Multiple timeout periods prevent rushed attacks
3. **Economic Bonds**: Significant ETH at stake for dishonest behavior
4. **Cascading Invalidity**: Invalid parents invalidate all descendants
5. **Withdrawal Delays**: Additional time buffer for bridge security

### Advanced Security Considerations

#### Bulk Invalidation Risks
- Validity proofs can invalidate multiple fault proof proposals
- Important to monitor for conflicting proposals
- Consider implications when building on top of proposals

#### L1 Checkpoint Security
- System relies on stored L1 block hashes
- Stale checkpoints could affect proof verification
- Regular checkpoint updates important for security

#### Fork Handling Security
- Bridge can update rollup reference for fork support
- Trust implications of ownership vs renounced ownership
- Consider withdrawal delays during fork transitions

#### Training Wheels Risks
- Centralized control features for early deployment
- Plan for progressive decentralization
- Monitor owner actions for transparency

#### Bond Economics
- Analyze attack costs vs potential profits
- Consider MEV implications of bond claiming
- Monitor for griefing attacks

### Security Best Practices
1. Always verify proposals are canonical before building on them
2. Monitor bulk invalidation events
3. Use appropriate withdrawal delays
4. Implement monitoring for anomalous behavior
5. Consider fork handling in integration design

## Data Availability Options

### Ethereum DA (Default)
- Uses Ethereum L1 for data availability
- Higher cost but maximum security
- No additional trust assumptions

### Celestia DA
- Alternative DA layer for cost reduction
- Requires Celestia light client
- Different security assumptions
- Separate Docker configurations

### Switching DA Layers
```bash
# Use Ethereum DA
just start-docker

# Use Celestia DA  
docker compose -f docker/compose-celestia.yml up
```

## Integration Points

### For Rollup Operators
1. Deploy Rollup.sol with appropriate configuration
2. Set up proposer service with whitelisted address
3. Optionally run challenger service for additional security
4. Monitor events for proposal activity
5. Configure Prometheus/Grafana for monitoring
6. Plan for progressive decentralization

### For Bridge Developers
1. Use `proposalIsCanonical()` to verify L2 state roots
2. Generate merkle proofs against canonical roots
3. Implement appropriate withdrawal delays
4. Handle bulk invalidation edge cases
5. Consider fork handling requirements
6. Monitor for root blacklisting events

### For Application Developers
1. Use the Web UI for user-facing interactions
2. Integrate with canonical proposals for state verification
3. Monitor proposal status for finality
4. Handle reorgs from bulk invalidation
5. Consider both fault proof and validity proof paths

### For Users
1. Choose between optimistic path (cheaper) or validity path (faster)
2. Monitor proposal status for withdrawals
3. Understand withdrawal delays and security periods
4. Use Web UI for simplified interactions

## Troubleshooting

### Common Issues

#### Proof Generation Failures
- Check SP1 version compatibility
- Verify sufficient memory allocation
- Monitor for L1 RPC issues
- Check block range size limits

#### Proposal Conflicts
- Monitor for bulk invalidation events
- Check parent proposal status
- Verify L2 finality before proposing
- Ensure correct interval alignment

#### Bond Issues
- Verify sufficient ETH balance
- Check bond amounts in configuration
- Monitor for failed transactions
- Ensure proper gas limits

#### Integration Problems
- Verify canonical proposal queries
- Check for proper error handling
- Monitor for contract pauses
- Handle edge cases properly

## Important Notes

- Do what has been asked; nothing more, nothing less
- NEVER create files unless they're absolutely necessary
- ALWAYS prefer editing existing files to creating new ones
- NEVER proactively create documentation files unless explicitly requested