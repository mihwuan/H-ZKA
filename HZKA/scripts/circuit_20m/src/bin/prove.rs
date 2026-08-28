// bin/prove.rs — Generate a Groth16 proof for the aggregation circuit.
//
// Usage:
//   /usr/bin/time -v cargo run --release --features parallel --bin prove -- \
//       --pk build_agg/agg_pk.bin \
//       --witness witness.bin \
//       --out proof.bin

use ark_bn254::{Bn254, Fr};
use ark_groth16::Groth16;
use ark_serialize::{CanonicalDeserialize, CanonicalSerialize};
use ark_snark::SNARK;
use ark_std::rand::SeedableRng;
use clap::Parser;
use rand_chacha::ChaCha20Rng;
use std::fs;
use std::path::PathBuf;

use hzka_prover::aggregation::{AggregationCircuit, AggregationConfig};
use hzka_prover::poseidon_params::bn254_poseidon_config;
use hzka_prover::utils::timed;

#[derive(Parser, Debug)]
#[command(name = "prove", about = "Generate Groth16 proof")]
struct Args {
    /// Path to the proving key
    #[arg(long)]
    pk: PathBuf,

    /// Path to the witness
    #[arg(long)]
    witness: PathBuf,

    /// Output proof file
    #[arg(long)]
    out: PathBuf,
}

fn main() -> color_eyre::Result<()> {
    color_eyre::install()?;
    tracing_subscriber::fmt::init();
    let args = Args::parse();

    eprintln!("Loading proving key from {}...", args.pk.display());
    let pk_bytes = fs::read(&args.pk)?;
    let pk = ark_groth16::ProvingKey::<Bn254>::deserialize_compressed(&*pk_bytes)?;
    eprintln!("  PK loaded ({} bytes)", pk_bytes.len());

    eprintln!("Loading witness from {}...", args.witness.display());
    let _witness_bytes = fs::read(&args.witness)?;

    // Reconstruct the circuit with the witness data
    // In production, the witness file would contain the full assignment.
    let config = AggregationConfig {
        slots: 15,
        use_commitment: true,
    };
    let poseidon_config = bn254_poseidon_config();
    let circuit = AggregationCircuit::new(config, poseidon_config);

    let mut rng = ChaCha20Rng::seed_from_u64(0x5678);

    eprintln!("Generating Groth16 proof...");
    let (proof, elapsed) = timed("proving", || {
        Groth16::<Bn254>::prove(&pk, circuit, &mut rng)
            .expect("Proof generation failed")
    });

    // Serialise proof
    let mut proof_bytes = Vec::new();
    proof.serialize_compressed(&mut proof_bytes)?;
    fs::write(&args.out, &proof_bytes)?;

    eprintln!("  proof size:   {} bytes", proof_bytes.len());
    eprintln!("  written to:   {}", args.out.display());
    eprintln!("  proving time: {elapsed:.2}s");

    Ok(())
}
