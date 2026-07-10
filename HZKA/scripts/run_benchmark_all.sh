#!/bin/bash
set -e
export BASE_DIR="/datastore/uitchain/hzka_benchmark"
export PATH="$BASE_DIR/.cargo/bin:$BASE_DIR/.local/bin:$BASE_DIR/node-v20/bin:$PATH"

# BƠM 64GB RAM CHO NODE.JS (RẤT QUAN TRỌNG)
export NODE_OPTIONS="--max-old-space-size=65536"
export PROVER_BIN="$BASE_DIR/workspace/rust_prover/target/release/hzka_prover"

cd $BASE_DIR/workspace

cat << 'JS_EOF' > benchmark_all.js
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const BENCH_DIR = path.join(process.cwd(), 'bench_data');
const TEST_SIZES = [500_000, 1_000_000, 2_000_000, 4_000_000, 5_000_000, 8_000_000, 10_000_000, 11_000_000, 11_500_000, 12_000_000];
const ITERATIONS = 3;

function run(cmd) { try { execSync(cmd, { cwd: BENCH_DIR, stdio: 'pipe' }); } catch(e){} }

async function benchmarkSize(targetConstraints) {
    const prefix = `circuit_${targetConstraints}`;
    const circomFile = path.join(BENCH_DIR, `${prefix}.circom`);
    fs.writeFileSync(circomFile, `pragma circom 2.0.0; template Bench(n) { signal input a; signal output b; signal acc[n+1]; acc[0] <== a; for (var i = 0; i < n; i++) { acc[i+1] <== acc[i] * acc[i]; } b <== acc[n]; } component main = Bench(${targetConstraints});`);

    console.log(`\n Đang biên dịch mạch ${(targetConstraints / 1e6).toFixed(1)}M (Quá trình này tốn rất nhiều RAM và thời gian, xin vui lòng đợi)...`);
    run(`circom ${circomFile} --r1cs --wasm -o ${BENCH_DIR}`);

    const wasm = path.join(BENCH_DIR, `${prefix}_js`, `${prefix}.wasm`);
    const r1cs = path.join(BENCH_DIR, `${prefix}.r1cs`);

    let times = [];
    for (let i = 1; i <= ITERATIONS; i++) {
        console.log(`   + Đang chạy lõi Rust Prover lần ${i}...`);
        const out = execSync(`"${process.env.PROVER_BIN}" "${wasm}" "${r1cs}"`, { cwd: BENCH_DIR, encoding: 'utf-8' });
        const match = out.match(/PROVER_TIME_MS:(\d+)/);
        times.push(match ? parseInt(match[1]) : 0);
    }

    console.log(` [Dọn dẹp] Xóa rác mạch ${(targetConstraints/1e6).toFixed(1)}M để giải phóng ổ cứng...`);
    run(`rm -rf ${prefix}*`);

    const avg = times.reduce((a, b) => a + b, 0) / ITERATIONS;
    return { constraints: targetConstraints, t1: times[0], t2: times[1], t3: times[2], avg };
}

async function main() {
    if (!fs.existsSync(BENCH_DIR)) fs.mkdirSync(BENCH_DIR, { recursive: true });
    
    // In Header trước khi bắt đầu vòng lặp
    console.log('\n=======================================================================');
    console.log(' Mạch     |   Lần 1 (s) |   Lần 2 (s) |   Lần 3 (s) | Trung Bình (s)');
    console.log('-----------------------------------------------------------------------');
    
    for (const size of TEST_SIZES) {
        // Chạy benchmark cho từng mạch
        const r = await benchmarkSize(size);
        
        // In kết quả ngay sau khi mạch chạy xong
        console.log(` ${(r.constraints / 1e6).toFixed(1).padStart(6)}M      | ${(r.t1/1000).toFixed(3).padStart(9)} | ${(r.t2/1000).toFixed(3).padStart(9)} | ${(r.t3/1000).toFixed(3).padStart(9)} | ${(r.avg/1000).toFixed(3).padStart(11)} `);
    }
    
    console.log('=======================================================================');
}
main();
JS_EOF

node benchmark_all.js