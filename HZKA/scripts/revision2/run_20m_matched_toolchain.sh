#!/usr/bin/env bash
set -euo pipefail

# Matched-toolchain 20M run for H-ZKA manuscript alignment.
# Runs only on Linux host with Rust harness that exposes:
#   --bin build_agg, --bin witness, --bin prove, --bin verify

usage() {
  cat <<'EOF'
Usage:
  bash run_20m_matched_toolchain.sh \
    --repo-root /path/to/H-ZKA/HZKA \
    --crate-dir /path/to/arkworks_harness \
    --input /path/to/input_full.json

Optional:
  --run-id <id>               default: UTC timestamp
  --round <n>                 default: 1
  --cluster-id <id>           default: 0
  --slots <n>                 default: 15

Outputs:
  <repo-root>/result/circuit_20M/<run-id>/
EOF
}

REPO_ROOT=""
CRATE_DIR=""
INPUT_JSON=""
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
ROUND="1"
CLUSTER_ID="0"
SLOTS="15"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --crate-dir) CRATE_DIR="$2"; shift 2 ;;
    --input) INPUT_JSON="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --round) ROUND="$2"; shift 2 ;;
    --cluster-id) CLUSTER_ID="$2"; shift 2 ;;
    --slots) SLOTS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$REPO_ROOT" || -z "$CRATE_DIR" || -z "$INPUT_JSON" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$CRATE_DIR/Cargo.toml" ]]; then
  echo "Missing Cargo.toml in crate dir: $CRATE_DIR"
  exit 1
fi

if [[ ! -f "$INPUT_JSON" ]]; then
  echo "Missing input json: $INPUT_JSON"
  exit 1
fi

OUT_ROOT="$REPO_ROOT/result/circuit_20M"
RUN_DIR="$OUT_ROOT/$RUN_ID"
BUILD_DIR="$RUN_DIR/build_agg"
mkdir -p "$BUILD_DIR"

echo "== Preflight =="
echo "run_id=$RUN_ID"
echo "repo_root=$REPO_ROOT"
echo "crate_dir=$CRATE_DIR"
echo "input_json=$INPUT_JSON"

{
  echo "run_id: $RUN_ID"
  echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host: $(hostname)"
  echo "kernel: $(uname -a)"
  echo "slots: $SLOTS"
  echo "public_inputs_interface: commitment"
  echo "public_inputs_expected_count: 3"
  echo "cluster_id: $CLUSTER_ID"
  echo "round: $ROUND"
  echo "security_curve: BN254"
  echo "security_target_bits: 128"
  echo "statement: verify B_max=15 inner Groth16 proofs and StateTransition(rt_old_j, tx_j)=rt_new_j for each slot"
  echo "toolchain: Rust/Arkworks with feature parallel"
} > "$RUN_DIR/manifest.pre_run.txt"

{
  echo "== lscpu =="
  lscpu || true
  echo
  echo "== free -h =="
  free -h || true
  echo
  echo "== rust toolchain =="
  rustc --version
  cargo --version
  echo
  echo "== git head =="
  git -C "$CRATE_DIR" rev-parse HEAD || true
  git -C "$CRATE_DIR" status --porcelain || true
} > "$RUN_DIR/environment.txt"

pushd "$CRATE_DIR" >/dev/null

echo "== Step 1: Build aggregation circuit =="
/usr/bin/time -v cargo run --release --features parallel --bin build_agg -- \
  --slots "$SLOTS" --public-inputs commitment --out "$BUILD_DIR" \
  2> "$RUN_DIR/build_agg.time"

echo "== Step 2: Record identity =="
sha256sum "$BUILD_DIR/agg.r1cs" "$BUILD_DIR/agg_pk.bin" "$BUILD_DIR/agg_vk.bin" > "$RUN_DIR/artifact.sha256"
cargo tree --locked > "$RUN_DIR/deps.lock.txt"

echo "== Step 3: Witness generation =="
/usr/bin/time -v cargo run --release --features parallel --bin witness -- \
  --circuit "$BUILD_DIR/agg.r1cs" --input "$INPUT_JSON" \
  --out "$RUN_DIR/witness.bin" \
  2> "$RUN_DIR/witness.time"

echo "== Step 4: Prove (3 independent runs) =="
for i in 1 2 3; do
  /usr/bin/time -v cargo run --release --features parallel --bin prove -- \
    --pk "$BUILD_DIR/agg_pk.bin" --witness "$RUN_DIR/witness.bin" \
    --out "$RUN_DIR/proof_${i}.bin" \
    2> "$RUN_DIR/prove_${i}.time"
done

echo "== Step 5: Verify and capture accepted public inputs =="
cargo run --release --bin verify -- \
  --vk "$BUILD_DIR/agg_vk.bin" --proof "$RUN_DIR/proof_1.bin" \
  --public "$RUN_DIR/public_1.json" \
  > "$RUN_DIR/verify.log" 2>&1

popd >/dev/null

python3 - "$RUN_DIR/public_1.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    v = json.load(f)
if isinstance(v, list):
    n = len(v)
elif isinstance(v, dict):
    n = len(v)
else:
    raise SystemExit("public_1.json must be list or object")
if n != 3:
    raise SystemExit(f"Public input count mismatch: got {n}, expected 3")
print(f"Public input count validated: {n}")
PY

cat > "$RUN_DIR/manifest.row.csv" <<'EOF'
run_id,host,cpu,slots,public_interface,constraints,curve,security_bits,witness_elapsed_s,prove1_elapsed_s,prove2_elapsed_s,prove3_elapsed_s,prove_mean_s,prove_ci95_s,rss_witness_kib,rss_prove1_kib,rss_prove2_kib,rss_prove3_kib,verify_ok,source_hash
FILL_ME,AsusL40,Xeon Gold 6538Y+,15,commitment,FILL_ME,BN254,128,FILL_ME,FILL_ME,FILL_ME,FILL_ME,FILL_ME,FILL_ME,FILL_ME,FILL_ME,FILL_ME,FILL_ME,FILL_ME,FILL_ME
EOF

echo "Done. Artifacts written to: $RUN_DIR"
