# Arkworks Harness From Zero (No Original Harness Exists)

This playbook applies when there was never a checked-in Cargo harness in the repository.

Important: in this case, the implementation is new. The manuscript must state that clearly unless you obtain the historical harness later.

## Decision gate first

Before coding, pick one policy path:

1. New implementation path:
   - Build a new Rust/Arkworks harness now.
   - Mark 20M run as a new implementation validation.
2. Conservative manuscript path:
   - Keep 20M row as prediction only.
   - Do not claim matched replay of earlier nine-point harness.

If you choose path 1, continue below.

## Phase A. Create a dedicated harness repository

Create a separate repository or submodule, for example:

- hzka-arkworks-harness/

Suggested structure:

- Cargo.toml
- Cargo.lock
- src/bin/build_agg.rs
- src/bin/witness.rs
- src/bin/prove.rs
- src/bin/verify.rs
- src/lib.rs
- fixtures/
- tests/

Why separate repo: provenance is clearer and editor audit is easier.

## Phase A1. Bootstrap host toolchain (AsusL40 Linux)

Run on AsusL40:

```bash
sudo apt-get update
sudo apt-get install -y build-essential pkg-config libssl-dev git curl jq
curl https://sh.rustup.rs -sSf | sh -s -- -y
source "$HOME/.cargo/env"
rustup default stable
rustc --version
cargo --version
```

If you use tmux/screen on long runs, initialize rust env in that session too:

```bash
source "$HOME/.cargo/env"
```

## Phase B. Freeze cryptography and dependency versions

Requirements to lock:

1. Curve: BN254.
2. Security level: Groth16 over BN254, approximately 100 bits under exTNFS.
3. Parallel build feature enabled.
4. Locked dependency graph.

Acceptance criteria:

- cargo build --release --features parallel --bins --locked succeeds.
- cargo tree --locked is archived with experiment artifact.

## Phase C. Define CLI contracts exactly (must match experiment scripts)

Implement these binaries and arguments exactly:

1. build_agg
   - --slots 15
   - --public-inputs commitment
   - --out <dir>
   - Output files: agg.r1cs, agg_pk.bin, agg_vk.bin
2. witness
   - --circuit <agg.r1cs>
   - --input <input_full.json>
   - --out witness.bin
3. prove
   - --pk <agg_pk.bin>
   - --witness witness.bin
   - --out proof_i.bin
4. verify
   - --vk <agg_vk.bin>
   - --proof proof_1.bin
   - --public public_1.json

If these names and flags drift, your automation and reproducibility break.

## Phase D. Circuit semantics implementation checklist

The aggregation circuit must encode:

1. Statement logic:
   - verify B_max = 15 inner Groth16 proofs
   - for each slot j, check StateTransition(rt_old_j, tx_j) = rt_new_j
2. Public input interface:
   - exactly 3 public inputs: cluster commitment, cluster id, round
3. Commitment binding inside circuit:
   - include B_max - 1 Poseidon compressions in constraint count
4. Per-chain public-input variant is not accepted for this experiment.

Acceptance test:

- verification succeeds with exactly 3 public inputs
- verification fails if any of the 3 values changes

## Phase E. Add deterministic fixtures and negative tests

Minimum tests:

1. Positive test: valid 15-slot fixture verifies.
2. Tampered root test: one slot rt_new_j modified, proof must fail.
3. Tampered commitment test: public commitment changed, verify fails.
4. Public input arity test: arity not equal to 3 must fail.

Run tests with and without parallel feature.

## Phase F. Performance run protocol on AsusL40

Use the prepared project script:

- HZKA/scripts/revision2/run_20m_matched_toolchain.sh

Before the first real run, validate scaffold wiring:

```bash
cd HZKA/arkworks_harness
cargo build --release --features parallel --bins
cargo generate-lockfile
bash ../scripts/revision2/validate_arkworks_harness.sh --crate-dir "$(pwd)"
```

Run folder target:

- HZKA/result/circuit_20M/<run-id>/

Required captured files are already listed in:

- HZKA/result/circuit_20M/README.md

## Phase G. Summarize measurements and update manuscript

Summarize run:

- python3 HZKA/scripts/revision2/summarize_20m_run.py --run-dir <run-dir>

Then update:

1. Table 8 measured row.
2. Table 19 mean and CI over 3 runs.
3. Table 21 model errors against measured value.
4. Tables 14-15, Table 42, and sections that depend on S_agg.

## Phase H. Wording required for academic integrity

If no historical harness was recovered, use wording like:

- We implemented a new Rust/Arkworks harness matching the manuscript interface and cryptographic assumptions, then measured the 20M circuit on AsusL40 under the same host class and methodology.

Avoid wording that implies strict replay of the original nine-point codebase.
