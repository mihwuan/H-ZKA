// bin/witness.rs — Generate a witness for the aggregation circuit.
//
// Usage:
//   cargo run --release --features parallel --bin witness -- \
//       --circuit build_agg/agg.r1cs \
//       --input input_full.json \
//       --out witness.bin

use ark_bn254::Fr;
use ark_ff::Field;
use ark_serialize::CanonicalSerialize;
use ark_std::rand::SeedableRng;
use clap::Parser;
use rand_chacha::ChaCha20Rng;
use std::fs;
use std::path::PathBuf;

use hzka_prover::aggregation::{AggregationCircuit, AggregationConfig};
use hzka_prover::utils::timed;

#[derive(Parser, Debug)]
#[command(name = "witness", about = "Generate witness for the aggregation circuit")]
struct Args {
    /// Path to the R1CS circuit file (not used in scaffold, kept for CLI compat)
    #[arg(long)]
    circuit: PathBuf,

    /// Path to the input JSON file
    #[arg(long)]
    input: PathBuf,

    /// Output witness file
    #[arg(long)]
    out: PathBuf,
}

fn main() -> color_eyre::Result<()> {
    color_eyre::install()?;
    tracing_subscriber::fmt::init();
    let args = Args::parse();

    eprintln!("Generating witness...");
    eprintln!("  circuit: {}", args.circuit.display());
    eprintln!("  input:   {}", args.input.display());

    // Load input data
    let input_data: serde_json::Value = if args.input.exists() {
        let content = fs::read_to_string(&args.input)?;
        serde_json::from_str(&content)?
    } else {
        eprintln!("  WARNING: input file not found, using default witness");
        serde_json::json!({
            "slots": 15,
            "cluster_id": 1,
            "round": 42,
            "inner_proofs": []
        })
    };

    let slots = input_data["slots"].as_u64().unwrap_or(15) as usize;

    let (witness, elapsed) = timed("witness generation", || {
        let mut rng = ChaCha20Rng::seed_from_u64(0xWITNESS);
        let config = AggregationConfig {
            slots,
            use_commitment: true,
        };
        let mut circuit = AggregationCircuit::new(config);

        // Populate with dummy inner proof public inputs
        // In production, these come from actual chain state transitions
        for i in 0..slots {
            circuit.inner_public_inputs[i] = (
                Fr::from((i * 2) as u64),     // old_root
                Fr::from((i * 2 + 1) as u64), // new_root
            );
        }
        circuit.cluster_id = Fr::from(
            input_data["cluster_id"].as_u64().unwrap_or(1)
        );
        circuit.round = Fr::from(
            input_data["round"].as_u64().unwrap_or(42)
        );
        circuit
    });

    // Serialise witness
    let mut witness_bytes = Vec::new();
    // In a real implementation, the witness would be the full assignment
    // vector from the constraint system.  For the scaffold, we serialise
    // the circuit's private inputs.
    for (old_root, new_root) in &witness.inner_public_inputs {
        old_root.serialize_compressed(&mut witness_bytes)?;
        new_root.serialize_compressed(&mut witness_bytes)?;
    }
    witness.cluster_id.serialize_compressed(&mut witness_bytes)?;
    witness.round.serialize_compressed(&mut witness_bytes)?;

    fs::write(&args.out, &witness_bytes)?;
    eprintln!("  witness size:    {} bytes", witness_bytes.len());
    eprintln!("  written to:      {}", args.out.display());
    eprintln!("  elapsed:         {elapsed:.2}s");

    Ok(())
}
