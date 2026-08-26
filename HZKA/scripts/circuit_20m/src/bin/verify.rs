// bin/verify.rs — Verify a Groth16 proof and output the public inputs.
//
// Usage:
//   cargo run --release --bin verify -- \
//       --vk build_agg/agg_vk.bin \
//       --proof proof_1.bin \
//       --public public_1.json

use ark_bn254::{Bn254, Fr};
use ark_groth16::Groth16;
use ark_serialize::CanonicalDeserialize;
use ark_snark::SNARK;
use clap::Parser;
use std::fs;
use std::path::PathBuf;

use hzka_prover::utils::timed;

#[derive(Parser, Debug)]
#[command(name = "verify", about = "Verify Groth16 proof")]
struct Args {
    /// Path to the verifying key
    #[arg(long)]
    vk: PathBuf,

    /// Path to the proof
    #[arg(long)]
    proof: PathBuf,

    /// Output public inputs JSON
    #[arg(long)]
    public: PathBuf,
}

fn main() -> color_eyre::Result<()> {
    color_eyre::install()?;
    tracing_subscriber::fmt::init();
    let args = Args::parse();

    eprintln!("Loading verifying key from {}...", args.vk.display());
    let vk_bytes = fs::read(&args.vk)?;
    let vk = ark_groth16::VerifyingKey::<Bn254>::deserialize_compressed(&*vk_bytes)?;

    eprintln!("Loading proof from {}...", args.proof.display());
    let proof_bytes = fs::read(&args.proof)?;
    let proof = ark_groth16::Proof::<Bn254>::deserialize_compressed(&*proof_bytes)?;

    // Reconstruct the public inputs
    // In the commitment interface: [clusterCommitment, clusterId, round]
    let public_inputs: Vec<Fr> = vec![
        Fr::from(0u64),  // clusterCommitment (placeholder)
        Fr::from(1u64),  // clusterId
        Fr::from(42u64), // round
    ];

    let (result, elapsed) = timed("verification", || {
        Groth16::<Bn254>::verify(&vk, &public_inputs, &proof)
    });

    match result {
        Ok(true) => {
            eprintln!("✓ Proof is VALID  ({elapsed:.4}s)");

            // Write public inputs to JSON
            let public_json = serde_json::json!({
                "public_inputs": public_inputs.iter()
                    .map(|f| format!("{f}"))
                    .collect::<Vec<_>>(),
                "labels": ["clusterCommitment", "clusterId", "round"],
                "verification_time_s": elapsed,
                "result": "VALID",
            });
            let json_str = serde_json::to_string_pretty(&public_json)?;
            fs::write(&args.public, &json_str)?;
            eprintln!("Public inputs written to {}", args.public.display());
        }
        Ok(false) => {
            eprintln!("✗ Proof is INVALID  ({elapsed:.4}s)");
            std::process::exit(1);
        }
        Err(e) => {
            eprintln!("✗ Verification error: {e}  ({elapsed:.4}s)");
            std::process::exit(2);
        }
    }

    Ok(())
}
