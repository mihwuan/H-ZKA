# HZKA Arkworks Harness (Scaffold)

This directory is a starter harness for the required binaries:

- build_agg
- witness
- prove
- verify

Current status: scaffold only.

It compiles and provides stable CLI contracts, but does not implement real Groth16 circuit synthesis/proving/verification yet.

The scaffold now enforces:

- Witness schema with exactly 15 ordered slots (0..14).
- Canonical public-input interface of size 3: cluster_commitment, cluster_id, round.
- Commitment mode only for build_agg.

## Build

```bash
cargo build --release --features parallel --bins
```

## Expected CLI

```bash
cargo run --release --features parallel --bin build_agg -- \
  --slots 15 --public-inputs commitment --out build_agg/

cargo run --release --features parallel --bin witness -- \
  --circuit build_agg/agg.r1cs --input input_full.json --out witness.bin

cargo run --release --features parallel --bin prove -- \
  --pk build_agg/agg_pk.bin --witness witness.bin --out proof_1.bin

cargo run --release --bin verify -- \
  --vk build_agg/agg_vk.bin --proof proof_1.bin --public public_1.json
```

## Ready-to-run 5-step sequence

Run from this directory [HZKA/arkworks_harness](HZKA/arkworks_harness).

1. Build circuit artifacts

```bash
cargo run --release --features parallel --bin build_agg -- \
  --slots 15 --public-inputs commitment --out build_agg/
```

2. Record identity

```bash
sha256sum build_agg/agg.r1cs build_agg/agg_pk.bin build_agg/agg_vk.bin
cargo tree --locked > build_agg/deps.lock.txt
```

3. Witness generation

```bash
/usr/bin/time -v cargo run --release --features parallel --bin witness -- \
  --circuit build_agg/agg.r1cs --input input_full.json \
  --out witness.bin
```

4. Prove (3 runs)

```bash
for i in 1 2 3; do
  /usr/bin/time -v cargo run --release --features parallel --bin prove -- \
    --pk build_agg/agg_pk.bin --witness witness.bin \
    --out proof_$i.bin 2> prove_$i.time
done
```

5. Verify and accepted public inputs

```bash
cargo run --release --bin verify -- \
  --vk build_agg/agg_vk.bin --proof proof_1.bin --public public_1.json
```

Prepared by default in this directory:

- input_full.json exists and matches 15-slot schema
- verify auto-creates public_1.json (canonical object) if it does not exist
- build_agg writes build_meta.json with statement, interface, source_hash, and constraint_target

## Implementation TODO

1. build_agg
   - Implement aggregation circuit with B_max=15.
   - Enforce commitment interface with exactly 3 public inputs.
   - Include commitment binding (B_max-1 Poseidon compressions) inside constraints.
2. witness
   - Implement full witness generation from real input schema.
3. prove
   - Implement Groth16 proving over BN254.
4. verify
   - Implement Groth16 verification and strict public input semantics.

## Input schema fixture

- fixtures/input_full.example.json

- input_full.json (ready default for step 3)

Use this as the baseline shape for input_full.json in the 20M workflow.

## Validation scripts in project

- HZKA/scripts/revision2/validate_arkworks_harness.sh
- HZKA/scripts/revision2/run_20m_matched_toolchain.sh
- HZKA/scripts/revision2/summarize_20m_run.py
