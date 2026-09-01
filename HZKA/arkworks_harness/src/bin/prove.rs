use anyhow::Result;
use clap::Parser;
use hzka_arkworks_harness::{read_bytes, sha256_hex, write_bytes};
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(name = "prove")]
#[command(about = "Generate proof artifact (scaffold)")]
struct Args {
    #[arg(long)]
    pk: PathBuf,
    #[arg(long)]
    witness: PathBuf,
    #[arg(long)]
    out: PathBuf,
}

fn main() -> Result<()> {
    let args = Args::parse();

    let pk = read_bytes(&args.pk)?;
    let witness = read_bytes(&args.witness)?;

    let proof_obj = serde_json::json!({
        "status": "scaffold",
        "note": "replace with real Groth16 proving",
        "pk_sha256": sha256_hex(&pk),
        "witness_sha256": sha256_hex(&witness),
    });

    let bytes = serde_json::to_vec(&proof_obj)?;
    write_bytes(&args.out, &bytes)?;

    println!("[prove] wrote scaffold proof to {}", args.out.display());
    Ok(())
}
