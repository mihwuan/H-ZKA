use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::path::Path;

pub const EXPECTED_PUBLIC_INPUTS: usize = 3;
pub const EXPECTED_SLOTS: usize = 15;

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum PublicInputsMode {
    Commitment,
}

impl PublicInputsMode {
    pub fn as_str(self) -> &'static str {
        match self {
            PublicInputsMode::Commitment => "commitment",
        }
    }
}

pub fn parse_public_inputs_mode(s: &str) -> Result<PublicInputsMode> {
    match s {
        "commitment" => Ok(PublicInputsMode::Commitment),
        _ => Err(anyhow!(
            "unsupported --public-inputs value: {s}. Expected: commitment"
        )),
    }
}

pub fn ensure_parent(path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create parent dir for {}", path.display()))?;
    }
    Ok(())
}

pub fn write_bytes(path: &Path, bytes: &[u8]) -> Result<()> {
    ensure_parent(path)?;
    fs::write(path, bytes).with_context(|| format!("failed to write {}", path.display()))
}

pub fn read_bytes(path: &Path) -> Result<Vec<u8>> {
    fs::read(path).with_context(|| format!("failed to read {}", path.display()))
}

pub fn sha256_hex(data: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(data);
    hex::encode(h.finalize())
}

pub fn sha256_file_hex(path: &Path) -> Result<String> {
    let bytes = read_bytes(path)?;
    Ok(sha256_hex(&bytes))
}

#[derive(Debug, Serialize, Deserialize)]
pub struct BuildMeta {
    pub version: String,
    pub slots: u32,
    pub public_inputs_mode: String,
    pub curve: String,
    pub security_bits: u32,
    pub constraint_target: u64,
    pub source_hash: String,
    pub implementation_status: String,
    pub note: String,
    pub statement: String,
    pub expected_public_inputs: [String; EXPECTED_PUBLIC_INPUTS],
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SlotInput {
    pub slot: u32,
    pub rt_old: String,
    pub tx: String,
    pub rt_new: String,
    pub inner_proof: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WitnessInput {
    pub cluster_id: u64,
    pub round: u64,
    pub cluster_commitment: String,
    pub slots: Vec<SlotInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublicInputsObject {
    pub cluster_commitment: String,
    pub cluster_id: u64,
    pub round: u64,
}

pub fn validate_witness_input(input: &WitnessInput, expected_slots: usize) -> Result<()> {
    if input.cluster_commitment.trim().is_empty() {
        return Err(anyhow!("cluster_commitment must be non-empty"));
    }
    if input.slots.len() != expected_slots {
        return Err(anyhow!(
            "slot count mismatch: got {}, expected {}",
            input.slots.len(),
            expected_slots
        ));
    }

    let mut seen = HashSet::with_capacity(input.slots.len());
    for (i, s) in input.slots.iter().enumerate() {
        if s.slot as usize != i {
            return Err(anyhow!(
                "slot ordering mismatch at index {}: got slot {}, expected {}",
                i,
                s.slot,
                i
            ));
        }
        if !seen.insert(s.slot) {
            return Err(anyhow!("duplicate slot index detected: {}", s.slot));
        }
        if s.rt_old.trim().is_empty()
            || s.tx.trim().is_empty()
            || s.rt_new.trim().is_empty()
            || s.inner_proof.trim().is_empty()
        {
            return Err(anyhow!("slot {} contains empty field(s)", s.slot));
        }
    }
    Ok(())
}

pub fn canonical_public_inputs(input: &WitnessInput) -> [String; EXPECTED_PUBLIC_INPUTS] {
    [
        input.cluster_commitment.clone(),
        input.cluster_id.to_string(),
        input.round.to_string(),
    ]
}

pub fn project_source_hash(project_root: &Path) -> Result<String> {
    let candidates = [
        "Cargo.toml",
        "src/lib.rs",
        "src/bin/build_agg.rs",
        "src/bin/witness.rs",
        "src/bin/prove.rs",
        "src/bin/verify.rs",
    ];
    let mut hasher = Sha256::new();
    for rel in candidates {
        let p = project_root.join(rel);
        if p.exists() {
            hasher.update(rel.as_bytes());
            hasher.update([0u8]);
            let b = fs::read(&p)
                .with_context(|| format!("failed to read source file {}", p.display()))?;
            hasher.update(&b);
            hasher.update([0u8]);
        }
    }
    Ok(hex::encode(hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_slot(slot: u32) -> SlotInput {
        SlotInput {
            slot,
            rt_old: "0x01".to_string(),
            tx: "0x02".to_string(),
            rt_new: "0x03".to_string(),
            inner_proof: "0x04".to_string(),
        }
    }

    #[test]
    fn valid_witness_passes() {
        let w = WitnessInput {
            cluster_id: 0,
            round: 1,
            cluster_commitment: "0xabc".to_string(),
            slots: (0..EXPECTED_SLOTS as u32).map(make_slot).collect(),
        };
        assert!(validate_witness_input(&w, EXPECTED_SLOTS).is_ok());
    }

    #[test]
    fn wrong_slot_count_fails() {
        let w = WitnessInput {
            cluster_id: 0,
            round: 1,
            cluster_commitment: "0xabc".to_string(),
            slots: vec![make_slot(0)],
        };
        assert!(validate_witness_input(&w, EXPECTED_SLOTS).is_err());
    }
}

pub fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    ensure_parent(path)?;
    let s = serde_json::to_string_pretty(value)
        .with_context(|| format!("failed to serialize json for {}", path.display()))?;
    fs::write(path, s).with_context(|| format!("failed to write {}", path.display()))
}

pub fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Result<T> {
    let s = fs::read_to_string(path)
        .with_context(|| format!("failed to read {}", path.display()))?;
    serde_json::from_str(&s).with_context(|| format!("failed to parse {}", path.display()))
}
