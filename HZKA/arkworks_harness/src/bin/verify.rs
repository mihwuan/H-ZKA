use anyhow::{ensure, Result};
use clap::Parser;
use hzka_arkworks_harness::{
    read_bytes, read_json, write_json, PublicInputsObject, EXPECTED_PUBLIC_INPUTS,
};
use serde_json::Value;
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(name = "verify")]
#[command(about = "Verify proof and handle public inputs (scaffold)")]
struct Args {
    #[arg(long)]
    vk: PathBuf,
    #[arg(long)]
    proof: PathBuf,
    #[arg(long)]
    public: PathBuf,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let _vk = read_bytes(&args.vk)?;
    let _proof = read_bytes(&args.proof)?;
    let public_path = args.public;

    let payload = if public_path.exists() {
        let v: Value = read_json(&public_path)?;
        validate_public_inputs(&v)?;
        v
    } else {
        let default = serde_json::json!({
            "cluster_commitment": "cluster_commitment_placeholder",
            "cluster_id": 0,
            "round": 1
        });
        write_json(&public_path, &default)?;
        default
    };

    println!("[verify] scaffold verify OK");
    println!("[verify] accepted public inputs: {}", payload);
    Ok(())
}

fn validate_public_inputs(v: &Value) -> Result<()> {
    match v {
        Value::Array(a) => {
            ensure!(
                a.len() == EXPECTED_PUBLIC_INPUTS,
                "public input count mismatch: got {}, expected {}",
                a.len(),
                EXPECTED_PUBLIC_INPUTS
            );
            for (i, it) in a.iter().enumerate() {
                ensure!(
                    it.is_string() || it.is_number(),
                    "public input at index {} must be string or number",
                    i
                );
            }
        }
        Value::Object(o) => {
            ensure!(
                o.len() == EXPECTED_PUBLIC_INPUTS,
                "public input count mismatch: got {}, expected {}",
                o.len(),
                EXPECTED_PUBLIC_INPUTS
            );
            let parsed: PublicInputsObject = serde_json::from_value(Value::Object(o.clone()))?;
            ensure!(
                !parsed.cluster_commitment.trim().is_empty(),
                "cluster_commitment must be non-empty"
            );
        }
        _ => anyhow::bail!("public input json must be array or object"),
    }
    Ok(())
}
