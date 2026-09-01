use anyhow::Result;
use clap::Parser;
use hzka_arkworks_harness::{
    canonical_public_inputs, read_bytes, read_json, sha256_hex, validate_witness_input,
    write_bytes, EXPECTED_SLOTS, WitnessInput,
};
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(name = "witness")]
#[command(about = "Generate witness artifact (scaffold)")]
struct Args {
    #[arg(long)]
    circuit: PathBuf,
    #[arg(long)]
    input: PathBuf,
    #[arg(long)]
    out: PathBuf,
}

fn main() -> Result<()> {
    let args = Args::parse();

    let circuit = read_bytes(&args.circuit)?;
    let input_json: WitnessInput = read_json(&args.input)?;
    validate_witness_input(&input_json, EXPECTED_SLOTS)?;

    let public_inputs = canonical_public_inputs(&input_json);

    let envelope = serde_json::json!({
        "status": "scaffold",
        "note": "replace with real witness generation",
        "circuit_sha256": sha256_hex(&circuit),
        "public_inputs": public_inputs,
        "input": input_json,
    });

    let bytes = serde_json::to_vec(&envelope)?;
    write_bytes(&args.out, &bytes)?;

    println!("[witness] wrote scaffold witness to {}", args.out.display());
    Ok(())
}
