# Obtain the Original Arkworks Cargo Harness (build_agg/witness/prove/verify)

This SOP is for the exact issue: workspace does not contain the manuscript Rust harness with four binaries.

Goal: obtain a harness that is admissible for the 20M matched-toolchain experiment.

## 0) What counts as acceptable

The harness is acceptable only if all checks below pass:

1. It is a Rust Cargo project with binaries:
   - build_agg
   - witness
   - prove
   - verify
2. It supports feature parallel and can build with:
   cargo build --release --features parallel --bins --locked
3. build_agg exposes commitment public-input mode for 3 public inputs.
4. Curve matches BN254 as used in the manuscript. Its security level is approximately 100 bits under exTNFS, not 128.
5. You can produce agg.r1cs, agg_pk.bin, agg_vk.bin, witness.bin, proof_i.bin and verify them.

## 1) Preferred path: recover the original harness used for nine measured points

Use this order. Stop as soon as one source is found and validated.

### 1.1 Recover from artifact archive used in revision

Ask the experiment owner for one of these:

- source tarball or zip of harness
- commit hash + private repository URL
- internal path on AsusL40 where benchmark was executed

Expected deliverables:

- Cargo.toml
- Cargo.lock
- src/bin/build_agg.rs
- src/bin/witness.rs
- src/bin/prove.rs
- src/bin/verify.rs

### 1.2 Recover from AsusL40 filesystem

On AsusL40, search for likely harness folders:

    find / -type f -name Cargo.toml 2>/dev/null | grep -Ei "ark|groth|agg|hzka|proof|zk"
    find / -type f -name "build_agg.rs" 2>/dev/null
    find / -type f -name "witness.rs" 2>/dev/null
    find / -type f -name "prove.rs" 2>/dev/null
    find / -type f -name "verify.rs" 2>/dev/null

If found:

    cd /path/to/harness
    cargo build --release --features parallel --bins --locked

### 1.3 Recover from old backups or CI workspace snapshots

Check:

- backup disks
- old VM snapshots
- CI cache buckets
- previous submission packages to editor

You only accept the source if Section 0 checks pass.

## 2) If original harness cannot be recovered

You must choose one of two policy-safe options:

1. Re-implement a new Rust harness and explicitly mark it as a new implementation in manuscript.
2. Keep manuscript claims as prediction-only and do not report it as matched validation.

Do not run Circom/snarkjs and present it as validation of Arkworks model. That will be methodologically inconsistent with the editor request.

## 3) Validation script for candidate harness

Use [HZKA/scripts/revision2/validate_arkworks_harness.sh](../scripts/revision2/validate_arkworks_harness.sh) before any 20M run.

Example:

    bash HZKA/scripts/revision2/validate_arkworks_harness.sh --crate-dir /path/to/harness

What it checks:

- Cargo project exists
- bins build_agg/witness/prove/verify exist in src/bin
- Cargo build with --features parallel --bins --locked succeeds
- records toolchain and source identity

## 4) Run sequence after harness is validated

Use the prepared runner:

    bash HZKA/scripts/revision2/run_20m_matched_toolchain.sh \
      --repo-root /path/to/H-ZKA/HZKA \
      --crate-dir /path/to/harness \
      --input /path/to/input_full.json \
      --slots 15 --cluster-id 0 --round 1

Then summarize:

    python3 HZKA/scripts/revision2/summarize_20m_run.py \
      --run-dir /path/to/H-ZKA/HZKA/result/circuit_20M/<run-id>

## 5) Minimal evidence bundle to keep

Inside one run folder in result/circuit_20M/<run-id>:

- manifest.pre_run.txt
- environment.txt
- artifact.sha256
- deps.lock.txt
- build_agg.time
- witness.time
- prove_1.time, prove_2.time, prove_3.time
- verify.log
- public_1.json
- summary_20m.json

This bundle is enough for auditability and table recomputation.
