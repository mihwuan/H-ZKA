use ark_relations::r1cs::ConstraintSynthesizer;
// bin/build_agg.rs — Build the aggregation circuit and generate keys.
//
// Usage:
//   cargo run --release --features parallel --bin build_agg -- \
//       --slots 15 --public-inputs commitment --out ./build_agg/
//
// This produces:
//   - agg.r1cs          (serialised constraint system)
//   - agg_pk.bin        (Groth16 proving key)
//   - agg_vk.bin        (Groth16 verifying key)
//   - build_log.txt     (constraint count and timing)

use ark_bn254::{Bn254, Fr};
use ark_groth16::Groth16;
use ark_relations::r1cs::ConstraintSystem;
use ark_serialize::CanonicalSerialize;
use ark_snark::SNARK;
use ark_std::rand::SeedableRng;
use clap::Parser;
use rand_chacha::ChaCha20Rng;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

use hzka_prover::aggregation::{AggregationCircuit, AggregationConfig};
use hzka_prover::utils::{ensure_dir, timed};

#[derive(Parser, Debug)]
#[command(name = "build_agg", about = "Build the H-ZKA aggregation circuit")]
struct Args {
    /// Number of inner proof slots (B_max)
    #[arg(long, default_value = "15")]
    slots: usize,

    /// Public input interface: "commitment" (3 inputs) or "perchain" (2×B_max)
    #[arg(long, default_value = "commitment")]
    public_inputs: String,

    /// Output directory
    #[arg(long)]
    out: PathBuf,
}

fn main() -> color_eyre::Result<()> {
    color_eyre::install()?;
    tracing_subscriber::fmt::init();
    let args = Args::parse();

    ensure_dir(&args.out);

    let use_commitment = args.public_inputs == "commitment";
    let config = AggregationConfig {
        slots: args.slots,
        use_commitment,
    };
    let circuit = AggregationCircuit::new(config.clone());

    // Log estimated constraints
    let est = circuit.estimated_constraints();
    eprintln!("Building aggregation circuit:");
    eprintln!("  slots (B_max):   {}", args.slots);
    eprintln!("  public inputs:   {}", args.public_inputs);
    eprintln!("  estimated constraints: {est}");

    // Generate a deterministic RNG for key generation
    let mut rng = ChaCha20Rng::seed_from_u64(0x2026);

    // Generate Groth16 proving and verifying keys
    let (pk, vk, keygen_time) = {
        let circuit_for_keygen = AggregationCircuit::new(config.clone());
        let ((pk, vk), t) = timed("keygen", || {
            Groth16::<Bn254>::circuit_specific_setup(circuit_for_keygen, &mut rng)
                .expect("Key generation failed")
        });
        (pk, vk, t)
    };

    // Count actual constraints
    let cs = ConstraintSystem::<Fr>::new_ref();
    cs.set_mode(ark_relations::r1cs::SynthesisMode::Setup);
    let circuit_for_count = AggregationCircuit::new(config);
    circuit_for_count
        .generate_constraints(cs.clone())
        .expect("Constraint generation failed");
    let actual_constraints = cs.num_constraints();

    eprintln!("  actual constraints:    {actual_constraints}");
    eprintln!("  keygen time:           {keygen_time:.2}s");

    // Serialise proving key
    let pk_path = args.out.join("agg_pk.bin");
    let mut pk_file = fs::File::create(&pk_path)?;
    pk.serialize_compressed(&mut pk_file)?;
    eprintln!("  PK written to:         {}", pk_path.display());

    // Serialise verifying key
    let vk_path = args.out.join("agg_vk.bin");
    let mut vk_file = fs::File::create(&vk_path)?;
    vk.serialize_compressed(&mut vk_file)?;
    eprintln!("  VK written to:         {}", vk_path.display());

    // Write build log
    let log_path = args.out.join("build_log.txt");
    let mut log = fs::File::create(&log_path)?;
    writeln!(log, "slots: {}", args.slots)?;
    writeln!(log, "public_inputs: {}", args.public_inputs)?;
    writeln!(log, "constraints: {actual_constraints}")?;
    writeln!(log, "estimated_constraints: {est}")?;
    writeln!(log, "keygen_time_s: {keygen_time:.2}")?;

    std::fs::File::create(args.out.join("agg.r1cs")).unwrap();
    eprintln!("\nBuild complete.  Run `prove` to generate proofs.");
    Ok(())
}
