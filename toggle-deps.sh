#!/bin/bash

# Script to switch between GitHub and local REVM/Kona development

usage() {
    echo "Usage: $0 [github|local]"
    echo ""
    echo "Switch between GitHub and local REVM/Kona dependencies:"
    echo "  github - Use GitHub dependencies (default)"
    echo "  local  - Use local development paths"
    echo ""
    echo "Example:"
    echo "  $0 local    # Switch to local development"
    echo "  $0 github   # Switch back to GitHub"
    exit 1
}

MODE=${1:-github}

if [[ "$MODE" != "github" && "$MODE" != "local" ]]; then
    usage
fi

echo "🔧 Switching dependencies to: $MODE"

# Create backup
cp .cargo/config.toml .cargo/config.toml.bak

if [ "$MODE" = "local" ]; then
    echo "📁 Switching to local development..."
    
    # Create a new config with local patches
    cat > .cargo/config.toml << 'EOF'
[patch."https://github.com/op-rs/kona"]
kona-mpt = { path = "../kona3/crates/proof/mpt" }
kona-derive = { path = "../kona3/crates/protocol/derive" }
kona-driver = { path = "../kona3/crates/protocol/driver" }
kona-preimage = { path = "../kona3/crates/proof/preimage" }
kona-executor = { path = "../kona3/crates/proof/executor" }
kona-proof = { path = "../kona3/crates/proof/proof" }
kona-client = { path = "../kona3/bin/client" }
kona-host = { path = "../kona3/bin/host" }
kona-providers-alloy = { path = "../kona3/crates/providers/providers-alloy" }
kona-rpc = { path = "../kona3/crates/node/rpc" }
kona-protocol = { path = "../kona3/crates/protocol/protocol" }
kona-registry = { path = "../kona3/crates/protocol/registry" }
kona-genesis = { path = "../kona3/crates/protocol/genesis" }
kona-std-fpvm = { path = "../kona3/crates/proof/std-fpvm" }
kona-std-fpvm-proc = { path = "../kona3/crates/proof/std-fpvm-proc" }
kona-cli = { path = "../kona3/crates/utilities/cli" }
kona-comp = { path = "../kona3/crates/protocol/comp" }
kona-hardforks = { path = "../kona3/crates/protocol/hardforks" }
kona-interop = { path = "../kona3/crates/protocol/interop" }
kona-macros = { path = "../kona3/crates/node/macros" }
kona-p2p = { path = "../kona3/crates/node/p2p" }
kona-proof-interop = { path = "../kona3/crates/proof/proof-interop" }
kona-serde = { path = "../kona3/crates/utilities/serde" }
kona-engine = { path = "../kona3/crates/node/engine" }

[patch.crates-io]
revm = { path = "../revm/crates/revm" }
revm-bytecode = { path = "../revm/crates/bytecode" }
revm-context = { path = "../revm/crates/context" }
revm-context-interface = { path = "../revm/crates/context/interface" }
revm-database = { path = "../revm/crates/database" }
revm-database-interface = { path = "../revm/crates/database/interface" }
revm-handler = { path = "../revm/crates/handler" }
revm-inspector = { path = "../revm/crates/inspector" }
revm-interpreter = { path = "../revm/crates/interpreter" }
revm-precompile = { path = "../revm/crates/precompile" }
revm-primitives = { path = "../revm/crates/primitives" }
revm-state = { path = "../revm/crates/state" }
op-revm = { path = "../revm/crates/optimism" }
EOF
    
    echo "✅ Switched to local dependencies"
    echo "⚠️  Make sure your local repos are at:"
    echo "   - REVM: ../revm"
    echo "   - Kona: ../kona3"
else
    echo "🌐 Switching to GitHub dependencies..."
    
    # Create config with GitHub patches
    cat > .cargo/config.toml << 'EOF'
[patch."https://github.com/op-rs/kona"]
kona-mpt = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-derive = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-driver = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-preimage = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-executor = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-proof = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-client = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-host = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-providers-alloy = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-rpc = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-protocol = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-registry = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-genesis = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-std-fpvm = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-std-fpvm-proc = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-cli = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-comp = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-hardforks = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-interop = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-macros = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-p2p = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-proof-interop = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-serde = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }
kona-engine = { git = "https://github.com/0xFacet/facet-kona", branch = "facet-initial-changes" }

[patch.crates-io]
revm = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
revm-bytecode = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
revm-context = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
revm-context-interface = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
revm-database = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
revm-database-interface = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
revm-handler = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
revm-inspector = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
revm-interpreter = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
revm-precompile = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
revm-primitives = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
revm-state = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
op-revm = { git = "https://github.com/0xFacet/facet-revm", branch = "facet-initial-changes" }
EOF
    
    echo "✅ Switched to GitHub dependencies"
    echo "   - REVM: 0xFacet/facet-revm (branch: facet-initial-changes)"
    echo "   - Kona: 0xFacet/facet-kona (branch: facet-initial-changes)"
fi

echo ""
echo "🔄 Running cargo update to refresh dependencies..."
cargo update

echo ""
echo "🧹 Cleaning build cache..."
cargo clean

echo ""
echo "🔍 Checking build with kona-executor..."
cargo check -p kona-executor

echo ""
echo "✅ Done! Dependencies are now using: $MODE"