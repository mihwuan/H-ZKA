#!/usr/bin/env bash
# ===========================================================================
# H-ZKA: Execute the 20-million-constraint aggregation circuit.
#
# This script implements the exact sequence specified in TODO.tex Section 1
# (Item 6).  It must be run on the AsusL40 node (Xeon Gold 6538Y+, 16 vCPU,
# 200 GiB RAM) with at least 128 GiB free, using the Rust/Arkworks toolchain
# with the `parallel` feature enabled.
#
# Five matching conditions (recorded before the run starts):
#   1. Statement:   verify B_max=15 inner Groth16 proofs + StateTransition
#   2. Public-input interface:  3 public inputs (cluster commitment, cluster
#      id, round) — Algorithm 1's commitment interface, NOT per-chain
#   3. Security level:  128-bit, BN254
#   4. Toolchain:  Rust/Arkworks with `parallel` feature
#   5. Host:  AsusL40 (Xeon Gold 6538Y+, 16 vCPU, 200 GiB)
#
# Usage:
#   bash run_20m_circuit.sh
#
# Output directory: ../../result/circuit_20M/
# ===========================================================================

set -euo pipefail
cd "$(dirname "$0")"

RESULT_DIR="../../result/circuit_20M"
mkdir -p "${RESULT_DIR}"

echo "========================================================"
echo "  H-ZKA 20M Circuit Execution"
echo "  $(date -Iseconds)"
echo "========================================================"
echo

# Record host identity
echo "== Host identity =="
uname -a | tee "${RESULT_DIR}/host_info.txt"
lscpu | head -20 | tee -a "${RESULT_DIR}/host_info.txt"
free -h | tee -a "${RESULT_DIR}/host_info.txt"
echo

# ---------------------------------------------------------------------------
# Step 1: Build the aggregation circuit at B_max=15 with commitment interface.
#         Record the constraint count and the source hash.
# ---------------------------------------------------------------------------
echo "== Step 1: Build aggregation circuit (B_max=15, commitment interface) =="
cargo run --release --features parallel --bin build_agg -- \
    --slots 15 --public-inputs commitment --out "${RESULT_DIR}/build_agg/"

CONSTRAINT_COUNT=$(grep -oP 'constraints:\s*\K\d+' "${RESULT_DIR}/build_agg/build_log.txt" 2>/dev/null || echo "CHECK_MANUALLY")
echo "Constraint count: ${CONSTRAINT_COUNT}" | tee "${RESULT_DIR}/constraint_count.txt"
echo

# ---------------------------------------------------------------------------
# Step 2: Record identity before proving.
#         SHA-256 of R1CS, proving key, and verifying key.
#         Locked dependency tree for reproducibility.
# ---------------------------------------------------------------------------
echo "== Step 2: Record identity =="
sha256sum "${RESULT_DIR}/build_agg/agg.r1cs" \
          "${RESULT_DIR}/build_agg/agg_pk.bin" \
          "${RESULT_DIR}/build_agg/agg_vk.bin" \
    | tee "${RESULT_DIR}/identity_hashes.txt"

cargo tree --locked > "${RESULT_DIR}/deps.lock.txt"
echo "Dependency tree saved to deps.lock.txt"
echo

# ---------------------------------------------------------------------------
# Step 3: Witness generation, timed separately from proving.
# ---------------------------------------------------------------------------
echo "== Step 3: Witness generation (timed) =="
/usr/bin/time -v cargo run --release --features parallel --bin witness -- \
    --circuit "${RESULT_DIR}/build_agg/agg.r1cs" \
    --input input_full.json \
    --out "${RESULT_DIR}/witness.bin" \
    2>"${RESULT_DIR}/witness.time"

echo "Witness generation time:"
grep "wall clock" "${RESULT_DIR}/witness.time" || true
grep "Maximum resident" "${RESULT_DIR}/witness.time" || true
echo

# ---------------------------------------------------------------------------
# Step 4: Prove — three independent runs, peak RSS captured each time.
# ---------------------------------------------------------------------------
echo "== Step 4: Proving (3 independent runs) =="
for i in 1 2 3; do
    echo "--- Run ${i}/3 ---"
    /usr/bin/time -v cargo run --release --features parallel --bin prove -- \
        --pk "${RESULT_DIR}/build_agg/agg_pk.bin" \
        --witness "${RESULT_DIR}/witness.bin" \
        --out "${RESULT_DIR}/proof_${i}.bin" \
        2>"${RESULT_DIR}/prove_${i}.time"

    echo "  Wall clock:"
    grep "wall clock" "${RESULT_DIR}/prove_${i}.time" || true
    echo "  Peak RSS:"
    grep "Maximum resident" "${RESULT_DIR}/prove_${i}.time" || true
    echo
done

# ---------------------------------------------------------------------------
# Step 5: Verify, and record the public inputs actually accepted.
# ---------------------------------------------------------------------------
echo "== Step 5: Verify proof =="
cargo run --release --bin verify -- \
    --vk "${RESULT_DIR}/build_agg/agg_vk.bin" \
    --proof "${RESULT_DIR}/proof_1.bin" \
    --public "${RESULT_DIR}/public_1.json"

echo
echo "Verification complete.  Public inputs written to public_1.json"
echo

# ---------------------------------------------------------------------------
# Summary manifest
# ---------------------------------------------------------------------------
echo "== Manifest =="
cat <<EOF | tee "${RESULT_DIR}/manifest.txt"
Date:                 $(date -Iseconds)
Host:                 AsusL40 (Xeon Gold 6538Y+, 16 vCPU, 200 GiB)
Toolchain:            Rust/Arkworks (parallel feature)
Security:             128-bit, BN254
Statement:            B_max=15 inner Groth16 proofs, commitment interface
Public inputs:        3 (cluster commitment, cluster id, round)
Constraint count:     ${CONSTRAINT_COUNT}
Source hashes:        see identity_hashes.txt
Dependencies:         see deps.lock.txt
Witness time:         see witness.time
Prove runs:           prove_1.time, prove_2.time, prove_3.time
EOF

echo
echo "All outputs stored in ${RESULT_DIR}/"
echo "Run parse_20m_results.py to extract mean/CI and update the manuscript tables."
