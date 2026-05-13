#!/usr/bin/env node
/**
 * VM Groth16 Benchmark (PLAN B - C++ Rapidsnark)
 * ĐÃ CẬP NHẬT: 
 * 1. Lưu file .ptau ở thư mục riêng (Cache) để không bao giờ bị xóa.
 * 2. Fix lỗi "require is not defined" (CommonJS).
 * 3. Tăng giới hạn RAM cho quá trình tạo Witness để tránh OOM.
 * 4. Chỉ chạy test 2.0M Constraints để tối ưu thời gian trên Azure.
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const BENCH_DIR = path.join(process.cwd(), 'bench_groth16');
const PTAU_DIR = path.join(process.cwd(), 'ptau_cache'); // Đã thêm thư mục Cache an toàn
const TARGET = 20_000_000;
const TEST_SIZES = [500_000, 1_000_000, 2_000_000, 4_000_000, 5_000_000]; 
const NUM_RUNS = 3;

let SNARKJS = 'snarkjs';
const PROVER_BIN = '/usr/local/bin/prover';

function ptauPower(n) { return Math.ceil(Math.log2(n)); } // Tối ưu: Dùng đúng ptau 21 cho mạch 2M
function log(msg) { console.log(`[${new Date().toISOString()}] ${msg}`); }

function run(cmd, cwd) {
    const t0 = Date.now();
    try {
        const out = execSync(cmd, {
            cwd: cwd || BENCH_DIR, encoding: 'utf8',
            maxBuffer: 1024 * 1024 * 1024, timeout: 0
        });
        return { ok: true, ms: Date.now() - t0, out };
    } catch (e) {
        return { ok: false, ms: Date.now() - t0, err: e.message.substring(0, 500) };
    }
}

function fmt(ms) {
    if (ms < 1000) return `${Math.round(ms)}ms`;
    const s = ms / 1000;
    return s < 60 ? `${s.toFixed(1)}s` : `${(s / 60).toFixed(1)}m`;
}

function writeCircuit(n) {
    const iters = n;
    const src = `pragma circom 2.0.0;
template Bench(n) {
    signal input a;
    signal output b;
    signal acc[n+1];
    acc[0] <== a;
    for (var i = 0; i < n; i++) {
        acc[i+1] <== acc[i] * acc[i];
    }
    b <== acc[n];
}
component main = Bench(${iters});
`;
    const p = path.join(BENCH_DIR, `circuit_${n}.circom`);
    fs.writeFileSync(p, src);
    return p;
}

function ensurePtau(power) {
    if (power > 28) { power = 28; }
    
    // Đảm bảo thư mục cache tồn tại
    if (!fs.existsSync(PTAU_DIR)) fs.mkdirSync(PTAU_DIR, { recursive: true });
    
    const f = path.join(PTAU_DIR, `pot${power}.ptau`); // Lưu vào Cache
    
    if (fs.existsSync(f) && fs.statSync(f).size > 1000) {
        log(`  ptau ${power} exists (${(fs.statSync(f).size / 1e6).toFixed(1)} MB) in cache`);
        return f;
    }
    if (fs.existsSync(f)) fs.unlinkSync(f);

    const url = `https://storage.googleapis.com/zkevm/ptau/powersOfTau28_hez_final_${String(power).padStart(2, '0')}.ptau`;
    log(`  Downloading ptau ${power} from ${url}...`);
    const r = run(`curl -f -L -o "${f}" "${url}"`);
    if (!r.ok || !fs.existsSync(f) || fs.statSync(f).size < 1000) {
        log(`  Download failed, generating locally (slow for large powers)...`);
        const tmpPtau = f + '.tmp';
        run(`${SNARKJS} powersoftau new bn128 ${power} ${tmpPtau} -v`);
        run(`${SNARKJS} powersoftau prepare phase2 ${tmpPtau} ${f} -v`);
        if (fs.existsSync(tmpPtau)) fs.unlinkSync(tmpPtau);
    }
    if (!fs.existsSync(f) || fs.statSync(f).size < 1000) {
        throw new Error(`Failed to obtain ptau for power ${power}`);
    }
    return f;
}

async function benchmarkSize(targetConstraints) {
    const label = `${(targetConstraints / 1e6).toFixed(1)}M`;
    log(`\n${'═'.repeat(60)}`);
    log(`BENCHMARKING: ${label} constraints`);
    log(`${'═'.repeat(60)}`);

    const prefix = `circuit_${targetConstraints}`;
    const circomFile = writeCircuit(targetConstraints);

    log('  Compiling circom...');
    const comp = run(`circom ${circomFile} --r1cs --wasm --sym -o ${BENCH_DIR}`);
    if (!comp.ok) { log(`  COMPILE FAILED: ${comp.err}`); return null; }
    log(`  Compiled in ${fmt(comp.ms)}`);

    const r1cs = path.join(BENCH_DIR, `${prefix}.r1cs`);
    const info = run(`${SNARKJS} r1cs info "${r1cs}"`);
    const m = info.out?.match(/Constraints:\s*(\d+)/);
    const actual = m ? parseInt(m[1]) : targetConstraints;
    log(`  Actual constraints: ${actual.toLocaleString()}`);

    const power = ptauPower(actual);
    const ptau = ensurePtau(power);

    const zkey = path.join(BENCH_DIR, `${prefix}.zkey`);
    log('  Groth16 setup (Node.js)...');
    const setup = run(`${SNARKJS} groth16 setup "${r1cs}" "${ptau}" "${zkey}"`);
    if (!setup.ok) { log(`  SETUP FAILED: ${setup.err}`); return null; }
    log(`  Setup done in ${fmt(setup.ms)}`);

    const vkey = path.join(BENCH_DIR, `${prefix}_vk.json`);
    run(`${SNARKJS} zkey export verificationkey "${zkey}" "${vkey}"`);

    const inputFile = path.join(BENCH_DIR, 'input.json');
    fs.writeFileSync(inputFile, JSON.stringify({ a: "5" }));

    const wasm = path.join(BENCH_DIR, `${prefix}_js`, `${prefix}.wasm`);
    const witnessScript = path.join(BENCH_DIR, `${prefix}_js`, `generate_witness.js`);
    const wtnsFile = path.join(BENCH_DIR, `${prefix}.wtns`);
    const proofFile = path.join(BENCH_DIR, `${prefix}_proof.json`);
    const pubFile = path.join(BENCH_DIR, `${prefix}_public.json`);

    const proveTimes = [];
    for (let i = 0; i < NUM_RUNS; i++) {
        log(`  Prove run ${i + 1}/${NUM_RUNS} (Rapidsnark C++)...`);

        try { execSync('sync && sudo sh -c "echo 3 > /proc/sys/vm/drop_caches" 2>/dev/null || true', { encoding: 'utf8' }); } catch { }

        const t0 = Date.now();

        // Node gọi Witness có ép RAM 16GB
        const genWtns = run(`node --max-old-space-size=16384 "${witnessScript}" "${wasm}" "${inputFile}" "${wtnsFile}"`);
        if (!genWtns.ok) {
            log(`  WITNESS GEN FAILED: ${genWtns.err}`);
            continue;
        }

        const prove = run(`${PROVER_BIN} "${zkey}" "${wtnsFile}" "${proofFile}" "${pubFile}"`);
        const elapsed = Date.now() - t0;

        if (!prove.ok) {
            log(`  PROVE FAILED: ${prove.err}`);
            if (prove.err.includes('memory') || prove.err.includes('Killed')) {
                log('  → Out of memory / Killed by OS. Skipping this size.');
                return null;
            }
            continue;
        }
        proveTimes.push(elapsed);
        log(`  Run ${i + 1}: ${fmt(elapsed)}`);
    }

    if (proveTimes.length === 0) { log('  All runs failed'); return null; }

    const verify = run(`${SNARKJS} groth16 verify "${vkey}" "${pubFile}" "${proofFile}"`);
    const valid = verify.out?.includes('OK') || false;
    log(`  Verify: ${valid ? 'OK ✓' : 'FAILED ✗'} (${fmt(verify.ms)})`);

    const mean = proveTimes.reduce((a, b) => a + b, 0) / proveTimes.length;
    const std = proveTimes.length > 1
        ? Math.sqrt(proveTimes.reduce((s, v) => s + (v - mean) ** 2, 0) / (proveTimes.length - 1))
        : 0;
    const usPerConstraint = (mean * 1000) / actual;

    // DỌN DẸP CHỈ XÓA FILE TẠM TRONG BENCH_DIR, KHÔNG CHẠM VÀO PTAU_DIR
    try {
        log('  Cleaning up large circuit files to save disk space...');
        const filesToDelete = [r1cs, zkey, wtnsFile, wasm, vkey, proofFile, pubFile, circomFile];
        filesToDelete.forEach(f => {
            if (fs.existsSync(f)) fs.unlinkSync(f);
        });
        const jsDir = path.join(BENCH_DIR, `${prefix}_js`);
        if (fs.existsSync(jsDir)) fs.rmSync(jsDir, { recursive: true, force: true });
    } catch (e) {
        log(`  Cleanup warning: ${e.message}`);
    }

    return {
        targetConstraints,
        actualConstraints: actual,
        runs: proveTimes.length,
        proveTimesMs: proveTimes,
        meanMs: Math.round(mean),
        stdMs: Math.round(std),
        usPerConstraint: parseFloat(usPerConstraint.toFixed(2)),
        verifyMs: verify.ms,
        verifyValid: valid,
        setupMs: setup.ms,
        compileMs: comp.ms,
    };
}

async function main() {
    console.log('='.repeat(70));
    console.log('  Groth16 Prover Benchmark (RAPIDSNARK C++ ACCELERATED)');
    console.log('='.repeat(70));

    log(`System: ${os.cpus()[0]?.model}, ${os.cpus().length} threads, ${(os.totalmem() / 1024 ** 3).toFixed(1)} GB RAM`);

    try {
        const npmPrefix = execSync('npm config get prefix', { encoding: 'utf8' }).trim();
        const snarkjsBin = path.join(npmPrefix, 'bin', 'snarkjs');
        if (fs.existsSync(snarkjsBin)) {
            SNARKJS = 'node --max-old-space-size=16384 ' + snarkjsBin;
        } else {
            throw new Error('Not found');
        }
    } catch {
        if (fs.existsSync('/usr/bin/snarkjs')) {
            SNARKJS = 'node --max-old-space-size=16384 /usr/bin/snarkjs';
        } else if (fs.existsSync('/usr/local/bin/snarkjs')) {
            SNARKJS = 'node --max-old-space-size=16384 /usr/local/bin/snarkjs';
        } else {
            log('ERROR: snarkjs not found anywhere.');
            process.exit(1);
        }
    }
    log(`Using snarkjs path: ${SNARKJS}`);

    if (!fs.existsSync(PROVER_BIN)) {
        log(`ERROR: Rapidsnark binary '${PROVER_BIN}' không tồn tại. VM chưa build C++ thành công.`);
        process.exit(1);
    } 

    fs.mkdirSync(BENCH_DIR, { recursive: true });

    // FIX LỖI COMMONJS CHO CIRCOM (Bắt buộc phải có dòng này)
    fs.writeFileSync(path.join(BENCH_DIR, 'package.json'), JSON.stringify({ type: "commonjs" }));

    const results = [];
    for (const size of TEST_SIZES) {
        const r = await benchmarkSize(size);
        if (r) {
            results.push(r);
            const tempReport = {
                experiment: 'Groth16 Rapidsnark C++ (In Progress)',
                timestamp: new Date().toISOString(),
                system: { cpu: os.cpus()[0]?.model, threads: os.cpus().length },
                measurements: results
            };
            fs.writeFileSync(path.join(BENCH_DIR, 'vm_benchmark_report_partial.json'), JSON.stringify(tempReport, null, 2));
            log(`  [Data Saved] Đã lưu kết quả tạm thời vào file vm_benchmark_report_partial.json.`);
        }
    }

    if (results.length === 0) {
        log('ERROR: No successful benchmarks. Có thể do thiếu RAM.');
        process.exit(1);
    }

    log(`\n${'═'.repeat(70)}`);
    let wSum = 0, wTot = 0;
    for (const r of results) {
        wSum += r.usPerConstraint * r.actualConstraints;
        wTot += r.actualConstraints;
    }
    const avgUs = wSum / wTot;
    const correctedUs = avgUs * 1.10;
    const extrapolatedS = (TARGET * correctedUs) / 1e6;

    console.log('\n Circuit Size     | Prove Time (C++) | µs/constraint');
    console.log('-'.repeat(55));
    for (const r of results) {
        console.log(` ${(r.actualConstraints / 1e6).toFixed(1).padStart(6)}M       | ${fmt(r.meanMs).padStart(12)} | ${r.usPerConstraint.toFixed(2)}`);
    }
    console.log('-'.repeat(55));
    console.log(` ► EXTRAPOLATED 20M: ${extrapolatedS.toFixed(1)}s`);

    const report = {
        experiment: 'Groth16 Rapidsnark C++ (Azure)',
        timestamp: new Date().toISOString(),
        system: { cpu: os.cpus()[0]?.model, threads: os.cpus().length },
        measurements: results,
        extrapolation: {
            targetConstraints: TARGET,
            extrapolatedSeconds: parseFloat(extrapolatedS.toFixed(1)),
        },
    };

    const reportPath = path.join(BENCH_DIR, 'vm_benchmark_report.json');
    fs.writeFileSync(reportPath, JSON.stringify(report, null, 2));
    
    // Dọn dẹp folder sau khi in xong
    if (fs.existsSync(BENCH_DIR)) fs.rmSync(BENCH_DIR, { recursive: true, force: true });
}

main().catch(e => { console.error(e); process.exit(1); });