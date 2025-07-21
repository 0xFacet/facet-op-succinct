# Facet ZK Fault Proofs (Forked from OP Succinct)

A zkEVM proving system for Facet that replaces the 7-day fraud proof window with ZK proofs, proved with Succinct SP1.

---

## 1. High-Level Architecture

```text
                 ┌────────────┐
                 │  L2 chain  │  ← OP-Stack execution
                 └─────▲──────┘
                       │ output roots
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Rollup.sol  (on L1)                           │
│                                                                 │
│  Fault-proof track      Validity-proof track                    │
│  ─────────────────       ───────────────────                    │
│  propose ─► challenge    proveBlock()                           │
│            │             │                                      │
│            ▼             ▼                                      │
│         prove()        instant                                  │
│            │                                                    │
│            └─► resolve ───── anchor update ─────────────────────┘
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Dual-track system:**
- **Fault-proof path**: Optimistic proposals with bonds, challengeable within a window, defended with ZK proofs
- **Validity path**: Direct ZK proof submission for immediate resolution. Overrides conflicting fault proofs

---

## 2. Main Components

| Component | Location | Description |
|-----------|----------|-------------|
| **Rollup.sol** | `contracts/src/` | Core dual-track rollup logic with proposal management, challenges, and proof verification |
| **Bridge contracts** | `contracts/src/` | L1ETHBridge and L2ERC20Bridge for cross-chain asset transfers |
| **Range program** | `programs/range/` | SP1 zkVM program that proves L2 state transitions |
| **Aggregation program** | `programs/aggregation/` | Combines multiple range proofs for efficient on-chain verification |
| **Proposer service** | `fault-proof/src/proposer.rs` | Monitors L2, submits proposals, defends challenges with proofs |
| **Challenger service** | [`fault-proof/src/challenger.rs`](fault-proof/src/challenger.rs) | Validates proposals, challenges incorrect ones, claims bonds |
| **Web interface** | `web/` | Next.js app for testing bridge operations |
| **Utilities** | `utils/` | Witness generation, data fetching, and proof infrastructure |

---

## 3. Key Flows

### Rollup Flows

**Fault Proof Flow**
- Proposer submits L2 state root with bond every `PROPOSAL_INTERVAL` blocks
- Challenge window opens (`MAX_CHALLENGE_SECS`)
- If challenged: proposer must defend with ZK proof within `MAX_PROVE_SECS`
- Resolution distributes bonds to winner

**Validity Proof Flow**
- Anyone calls `proveBlock()` with ZK proof of next L2 block
- Instant verification and resolution
- Conflicting fault proofs bulk invalidated
- No bonds required

### Bridging Flow

**Withdrawal Process**
- User initiates withdrawal on L2 → `MessagePassed` event
- Wait for block inclusion in canonical proposal
- Submit merkle proof to L1 bridge
- Finalize after withdrawal delay

---

## 4. Quick Start

### Docker (Recommended)
```bash
docker-compose up  # Starts local testnet with auto-deployed contracts and all services
```

### Manual Setup

**Prerequisites:**
- Rust 1.70+
- Foundry
- Node.js 18+ and pnpm
- Just (`cargo install just`)

```bash
# Clone and build
git clone https://github.com/0xFacet/zk-fault-proofs/
cd zk-fault-proofs
cargo build --release

# Configure environment
cp .env.example .env
# Edit .env with your values

# Deploy contracts
forge script contracts/script/DeployRollup.s.sol --broadcast

# Run services
cargo run --bin rollup-proposer --release
cargo run --bin rollup-challenger --release

# Start web interface
cd web && pnpm install && pnpm dev
```

---

## 5. Configuration

### Contract Constants
*Example values - see deployed contract for actuals*

- `PROPOSAL_INTERVAL`: L2 blocks between proposals (e.g., 30)
- `MAX_CHALLENGE_SECS`: Challenge window duration (e.g., 3600)
- `MAX_PROVE_SECS`: Proof submission deadline (e.g., 7200)
- `PROPOSER_BOND`: ETH stake for proposals (e.g., 0.1 ETH)
- `CHALLENGER_BOND`: ETH stake for challenges (e.g., 0.1 ETH)

### Environment Variables

See [`.env.example`](.env.example) for the complete list of required and optional variables:

```bash
# Required
L1_RPC              # L1 node RPC endpoint
L2_RPC              # L2 node RPC endpoint  
ROLLUP_ADDRESS      # Deployed Rollup.sol address
PRIVATE_KEY         # Service account private key

# Proving
PROVER_URL          # SP1 prover endpoint
SP1_PROVER_NETWORK_KEY  # Network prover API key

# Optional
CHALLENGER_ENABLED  # Run challenger service
TELEMETRY_ENDPOINT  # Metrics collection
```

---

## 6. Development

### Common Commands
```bash
just build-all                          # Build everything
just run-single <l2_block> prove=true   # Generate single block proof
just test-integration                   # Run integration tests
```

### Monitoring
- Prometheus metrics on port 9090
- Grafana dashboards in `docker/grafana/`

### Debugging
```bash
export RUST_LOG=debug
cast logs --address $ROLLUP_ADDRESS --from-block latest
```

---

## 7. Security Model

- **Economic security**: Proposer and challenger bonds incentivize honest behavior
- **Proof verification**: All proofs verified on-chain via SP1 verifier
- **Time delays**: Multiple timeout periods prevent rushed attacks
- **Censorship resistance**: Allowlisted proposers with fallback to permissionless after `FALLBACK_TIMEOUT_SECS`
- **Cascading invalidity**: Invalid proposals invalidate all descendants

---

## 8. Repository Structure

```text
op-succinct/
├── contracts/          # Solidity contracts and tests
├── programs/           # SP1 zkVM programs
├── fault-proof/        # Rust proposer/challenger services
├── utils/              # Shared utilities
├── scripts/            # Operational scripts
├── web/                # Bridge demo application
├── elf/                # Compiled zkVM binaries
└── docker/             # Container configurations
```

---

## Links

- [Documentation](https://docs.succinct.xyz/op-succinct) *(coming soon)*
- [SP1 zkVM](https://github.com/succinctlabs/sp1)
- [OP Stack](https://docs.optimism.io)

## License

MIT