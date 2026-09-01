#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash validate_arkworks_harness.sh --crate-dir /path/to/harness [--out /path/to/report_dir]

Checks:
  1) Cargo.toml exists
  2) src/bin/{build_agg,witness,prove,verify}.rs exist
  3) cargo build --release --features parallel --bins --locked succeeds
  4) emits report files with source/toolchain identity
EOF
}

CRATE_DIR=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --crate-dir) CRATE_DIR="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "$CRATE_DIR" ]]; then
  usage
  exit 1
fi

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$CRATE_DIR/harness_validation_$(date -u +%Y%m%dT%H%M%SZ)"
fi

mkdir -p "$OUT_DIR"

if [[ ! -f "$CRATE_DIR/Cargo.toml" ]]; then
  echo "ERROR: Cargo.toml not found in $CRATE_DIR"
  exit 1
fi

required=(build_agg witness prove verify)
for b in "${required[@]}"; do
  if [[ ! -f "$CRATE_DIR/src/bin/${b}.rs" ]]; then
    echo "ERROR: missing binary source: src/bin/${b}.rs"
    exit 1
  fi
done

{
  echo "timestamp_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "crate_dir: $CRATE_DIR"
  echo "host: $(hostname)"
  echo "kernel: $(uname -a)"
  echo "rustc: $(rustc --version)"
  echo "cargo: $(cargo --version)"
} > "$OUT_DIR/environment.txt"

if command -v git >/dev/null 2>&1; then
  {
    echo "git_head:"
    git -C "$CRATE_DIR" rev-parse HEAD || true
    echo
    echo "git_status_porcelain:"
    git -C "$CRATE_DIR" status --porcelain || true
  } > "$OUT_DIR/source_identity.txt"
fi

echo "Building harness with locked deps and parallel feature..."
(
  cd "$CRATE_DIR"
  cargo build --release --features parallel --bins --locked
) > "$OUT_DIR/build.log" 2>&1

(
  cd "$CRATE_DIR"
  sha256sum Cargo.toml Cargo.lock src/bin/build_agg.rs src/bin/witness.rs src/bin/prove.rs src/bin/verify.rs
) > "$OUT_DIR/source.sha256"

cat > "$OUT_DIR/result.txt" <<'EOF'
OK: harness validation passed.
Required binaries present: build_agg, witness, prove, verify.
Build succeeded with: cargo build --release --features parallel --bins --locked
EOF

echo "Validation passed. Report directory: $OUT_DIR"
