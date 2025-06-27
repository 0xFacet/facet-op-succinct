use std::env;

use alloy_primitives::Address;
use alloy_provider::ProviderBuilder;
use alloy_transport_http::reqwest::Url;
use anyhow::Result;
use clap::Parser;
use fault_proof::{
    rollup_contract::Rollup, prometheus::ChallengerGauge, rollup_challenger::RollupChallenger,
    utils::setup_logging,
};
use op_succinct_host_utils::metrics::{init_metrics, MetricsGauge};
use op_succinct_signer_utils::Signer;

#[derive(Parser)]
struct Args {
    #[arg(long, default_value = ".env.challenger")]
    env_file: String,
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