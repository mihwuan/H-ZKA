#!/bin/bash
set -e

# --- CẤU HÌNH ĐƯỜNG DẪN ---
export BASE_DIR="/datastore/uitchain/hzka_benchmark"
export RUSTUP_HOME="$BASE_DIR/.rustup"
export CARGO_HOME="$BASE_DIR/.cargo"
export LOCAL_BIN="$BASE_DIR/.local/bin"
export PATH="$CARGO_HOME/bin:$LOCAL_BIN:$BASE_DIR/node-v20/bin:$PATH"

mkdir -p $LOCAL_BIN

echo "--- 1. CÀI ĐẶT MÔI TRƯỜNG ---"
if ! command -v cargo &> /dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
fi
if ! command -v circom &> /dev/null; then
    git clone https://github.com/iden3/circom.git || true
    cd circom && cargo build --release && cp target/release/circom $LOCAL_BIN/ && cd ..
fi

if [ ! -d "$BASE_DIR/node-v20" ]; then
    wget -qO- https://nodejs.org/dist/v20.12.2/node-v20.12.2-linux-x64.tar.xz | tar -xJ -C "$BASE_DIR"
    mv "$BASE_DIR/node-v20.12.2-linux-x64" "$BASE_DIR/node-v20"
fi

WORKSPACE_DIR="$BASE_DIR/workspace"
mkdir -p "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"
if [ ! -d "node_modules/snarkjs" ]; then npm install snarkjs; fi
export PATH="$WORKSPACE_DIR/node_modules/.bin:$PATH"

echo "--- 2. KHỞI TẠO LÕI RUST (PHIÊN BẢN 0.6.0 MỚI NHẤT) ---"
if [ ! -d "rust_prover" ]; then cargo new rust_prover; fi
cd rust_prover

# KHÔNG CẦN ÉP LINKER, CHỈ CẦN DÙNG BẢN 0.6.0 LÀ MỌI LỖI TỰ BIẾN MẤT
cat << 'EOF' > Cargo.toml
[package]
name = "hzka_prover"
version = "0.1.0"
edition = "2021"

[dependencies]
ark-bn254 = "0.6.0"
ark-groth16 = { version = "0.6.0", features = ["parallel"] }
ark-snark = "0.6.0"
ark-circom = "0.6.0"
rand = "0.8"
EOF

cat << 'EOF' > src/main.rs
use ark_circom::{CircomBuilder, CircomConfig};
use ark_bn254::{Bn254, Fr}; // Thêm Fr (Trường vô hướng của Bn254)
use ark_groth16::Groth16;
use ark_snark::SNARK;
use rand::thread_rng;
use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 { return; }

    let wasm = &args[1];
    let r1cs = &args[2];

    // Dùng Fr thay vì Bn254 cho CircomConfig
    let cfg = CircomConfig::<Fr>::new(wasm, r1cs).unwrap();
    let mut builder = CircomBuilder::new(cfg);
    builder.push_input("a", 5);

    let circom = builder.setup();
    let mut rng = thread_rng();

    let (pk, _) = Groth16::<Bn254>::circuit_specific_setup(circom, &mut rng).unwrap();
    let circuit = builder.build().unwrap();

    let start_prove = Instant::now();
    let _proof = Groth16::<Bn254>::prove(&pk, circuit, &mut rng).unwrap();

    println!("PROVER_TIME_MS:{}", start_prove.elapsed().as_millis());
}
EOF

if [ ! -f "target/release/hzka_prover" ]; then
    echo "Đang biên dịch lõi Prover..."
    rm -f Cargo.lock
    cargo build --release
else
    echo "Binary đã sẵn sàng, bỏ qua biên dịch."
fi

PROVER_BIN="$PWD/target/release/hzka_prover"
cd ..

echo "--- 3. CHẠY BENCHMARK ---"
cat << EOF > benchmark.js
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const BENCH_DIR = path.join(process.cwd(), 'bench_data');
const TEST_SIZES = [100_000, 500_000, 1_000_000];

function run(cmd) { try { execSync(cmd, { cwd: BENCH_DIR, stdio: 'pipe' }); } catch(e){} }

async function benchmarkSize(targetConstraints) {
    const prefix = \`circuit_\${targetConstraints}\`;
    const circomFile = path.join(BENCH_DIR, \`\${prefix}.circom\`);
    fs.writeFileSync(circomFile, \`pragma circom 2.0.0; template Bench(n) { signal input a; signal output b; signal acc[n+1]; acc[0] <== a; for (var i = 0; i < n; i++) { acc[i+1] <== acc[i] * acc[i]; } b <== acc[n]; } component main = Bench(\${targetConstraints});\`);

    run(\`circom \${circomFile} --r1cs --wasm -o \${BENCH_DIR}\`);
    const wasm = path.join(BENCH_DIR, \`\${prefix}_js\`, \`\${prefix}.wasm\`);
    const r1cs = path.join(BENCH_DIR, \`\${prefix}.r1cs\`);

    const out = execSync(\`${PROVER_BIN} "\${wasm}" "\${r1cs}"\`, { cwd: BENCH_DIR, encoding: 'utf-8' });
    const match = out.match(/PROVER_TIME_MS:(\d+)/);
    return { constraints: targetConstraints, time: match ? parseInt(match[1]) : 0 };
}

async function main() {
    if (!fs.existsSync(BENCH_DIR)) fs.mkdirSync(BENCH_DIR, { recursive: true });
    const results = [];
    for (const size of TEST_SIZES) results.push(await benchmarkSize(size));
    console.log('\n Kích thước mạch | Thời gian Prover (Giây)');
    for (const r of results) console.log(\` \${(r.constraints / 1e6).toFixed(1).padStart(6)}M | \${(r.time / 1000).toFixed(3)}s \`);
}
main();
EOF

node benchmark.js