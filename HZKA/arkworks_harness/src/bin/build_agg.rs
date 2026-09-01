use anyhow::{ensure, Result};
use clap::Parser;
use hzka_arkworks_harness::{
    parse_public_inputs_mode, project_source_hash, write_bytes, write_json, BuildMeta,
};
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(name = "build_agg")]
#[command(about = "Build aggregation circuit artifacts (scaffold)")]
struct Args {
    #[arg(long)]
    slots: u32,
    #[arg(long = "public-inputs")]
    public_inputs: String,
    #[arg(long)]
    out: PathBuf,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let mode = parse_public_inputs_mode(&args.public_inputs)?;
    let source_hash = project_source_hash(std::path::Path::new(env!("CARGO_MANIFEST_DIR")))?;

    ensure!(
        args.slots == 15,
        "this scaffold expects --slots 15 for the target experiment"
    );

    std::fs::create_dir_all(&args.out)?;
    let r1cs = args.out.join("agg.r1cs");
    let pk = args.out.join("agg_pk.bin");
    let vk = args.out.join("agg_vk.bin");
    let meta = args.out.join("build_meta.json");

    let note = b"SCAFFOLD_ONLY: replace with real Arkworks circuit, keys, and constraints";
    write_bytes(&r1cs, note)?;
    write_bytes(&pk, note)?;
    write_bytes(&vk, note)?;

    write_json(
        &meta,
        &BuildMeta {
            version: env!("CARGO_PKG_VERSION").to_string(),
            slots: args.slots,
            public_inputs_mode: mode.as_str().to_string(),
            curve: "BN254".to_string(),
            security_bits: 128,
            constraint_target: 20_000_000,
            source_hash,
            implementation_status: "scaffold".to_string(),
            note: "No real circuit synthesis in this placeholder binary.".to_string(),
            statement: "Verify B_max=15 inner Groth16 proofs and StateTransition(rt_old_j, tx_j)=rt_new_j for each slot".to_string(),
            expected_public_inputs: [
                "cluster_commitment".to_string(),
                "cluster_id".to_string(),
                "round".to_string(),
            ],
        },
    )?;

    println!("[build_agg] wrote scaffold artifacts to {}", args.out.display());
    println!("[build_agg] public-input mode: {}", mode.as_str());
    Ok(())
}
