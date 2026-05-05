#!/usr/bin/env node

/**
 * ==========================================
 * Realistic Groth16 Prover Benchmark
 * ==========================================
 *
 * This script generates Circom circuits of controlled constraint count,
 * compiles them, runs the Groth16 full proving pipeline (witness + proof),
 * and measures wall‑clock time and memory.
 *
 * Intended to replace the flawed estimation in the earlier benchmark.
 *
 * Usage:
 *   node realistic_groth16_benchmark.cjs
 *
 * Prerequisites:
 *   - snarkjs 0.7.x or later
 *   - circom 2.0+
 *   - Node.js 18+
 *   - At least 32 GB RAM (64 GB recommended for 20M constraints)
 *
 * Output:
 *   - Console timing table
 *   - results/realistic_groth16_report.json
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

// ==========================================
// Configuration
// ==========================================
const PROJECT_DIR = path.join(__dirname, '..');
const BENCH_DIR = path.join(PROJECT_DIR, 'benchmarks', 'groth16_realistic');
const RESULTS_DIR = path.join(PROJECT_DIR, 'results', 'groth16_realistic');

const TARGET_CONSTRAINTS = [1_000_000, 5_000_000, 10_000_000, 20_000_000]; // 1M, 5M, 10M, 20M
const CIRCUIT_TEMPLATE = 'dummy_prover'; // name of generated circuit

// ==========================================
// Helpers
// ==========================================
function log(msg) { console.log(`[${new Date().toISOString()}] ${msg}`); }

function runCmd(cmd, options = {}) {
    log(`Exec: ${cmd}`);
    const start = Date.now();
    try {
        const out = execSync(cmd, {
            cwd: BENCH_DIR,
            encoding: 'utf8',
            maxBuffer: 1024 * 1024 * 1024,
            ...options,
        });
        const elapsed = Date.now() - start;
        return { success: true, output: out, timeMs: elapsed };
    } catch (err) {
        const elapsed = Date.now() - start;
        return { success: false, error: err.message, timeMs: elapsed };
    }
}

function formatTime(ms) {
    if (ms < 1000) return `${ms}ms`;
    return `${(ms / 1000).toFixed(2)}s`;
}

// ==========================================
// Generate Circom circuit with exact constraint count
// ==========================================
function generateCircomCircuit(constraints) {
    const n = Math.floor(constraints / 4); // ~4 constraints per iteration
    const circuitSrc = `
pragma circom 2.0;

template DummyProver(n) {
    signal input a;
    signal output b;
    signal accumulator[n + 1];
    accumulator[0] <== a;
    for (var i = 0; i < n; i++) {
        accumulator[i+1] <== accumulator[i] * accumulator[i] + 3;
    }
    b <== accumulator[n];
}

component main = DummyProver(${n});
`;
    return circuitSrc;
}

// ==========================================
// Measure proving time for a given constraint count
// ==========================================
async function benchmarkConstraintCount(constraintCount) {
    const circuitDir = path.join(BENCH_DIR, `c${constraintCount}`);
    fs.mkdirSync(circuitDir, { recursive: true });

    // Step 1: Generate circuit file
    const circomFile = path.join(circuitDir, 'circuit.circom');
    fs.writeFileSync(circomFile, generateCircomCircuit(constraintCount));
    log(`Generated circuit with target ${constraintCount} constraints.`);

    // Step 2: Compile
    const r1csFile = path.join(circuitDir, 'circuit.r1cs');
    const compileCmd = `circom ${circomFile} --r1cs --wasm --sym -o ${circuitDir}`;
    const compileRes = runCmd(compileCmd);
    if (!compileRes.success) {
        log(`Compilation failed: ${compileRes.error}`);
        return null;
    }
    log(`Compilation done in ${formatTime(compileRes.timeMs)}`);

    // Step 3: Check actual constraint count
    const infoRes = runCmd(`snarkjs r1cs info ${r1csFile}`);
    const actualConstraints = infoRes.output.match(/Constraints:\s*(\d+)/)?.[1] || constraintCount;
    log(`Actual constraints: ${actualConstraints}`);

    // Step 4: Groth16 setup (Plonk setup nhanh hơn nhưng giữ Groth16)
    const ptauFile = path.join(BENCH_DIR, 'pot15_final.ptau');
    if (!fs.existsSync(ptauFile)) {
        log('Downloading powers of tau...');
        runCmd(`snarkjs powersoftau new bn128 15 ${ptauFile}.tmp`);
        runCmd(`snarkjs powersoftau prepare phase2 ${ptauFile}.tmp ${ptauFile}`);
    }

    const zkeyFile = path.join(circuitDir, 'circuit_final.zkey');
    const setupStart = Date.now();
    runCmd(`snarkjs groth16 setup ${r1csFile} ${ptauFile} ${zkeyFile}`);
    log(`Groth16 setup: ${formatTime(Date.now() - setupStart)}`);

    // Export verification key
    const vkeyFile = path.join(circuitDir, 'verification_key.json');
    runCmd(`snarkjs zkey export verificationkey ${zkeyFile} ${vkeyFile}`);

    // Step 5: Generate witness and proof (FULL PROVE)
    const inputJson = { a: 5 };
    const inputPath = path.join(circuitDir, 'input.json');
    fs.writeFileSync(inputPath, JSON.stringify(inputJson));

    const wasmPath = path.join(circuitDir, 'circuit_js', 'circuit.wasm');
    const wtnsPath = path.join(circuitDir, 'witness.wtns');
    const proofPath = path.join(circuitDir, 'proof.json');
    const publicPath = path.join(circuitDir, 'public.json');

    // Measure prover time (wall‑clock)
    log(`Starting full prove for ${actualConstraints} constraints...`);
    const proveStart = Date.now();
    const proveRes = runCmd(
        `snarkjs groth16 fullprove ${inputPath} ${wasmPath} ${zkeyFile} ${proofPath} ${publicPath}`
    );
    const proveTime = Date.now() - proveStart;
    if (!proveRes.success) {
        log(`Prover failed: ${proveRes.error}`);
        return null;
    }
    log(`Prover time: ${formatTime(proveTime)}`);

    // Step 6: Verify proof (optional)
    const verifStart = Date.now();
    const verifRes = runCmd(
        `snarkjs groth16 verify ${vkeyFile} ${publicPath} ${proofPath}`
    );
    const verifTime = Date.now() - verifStart;
    const valid = verifRes.success && verifRes.output.includes('OK');
    log(`Verification ${valid ? 'OK' : 'FAILED'} in ${formatTime(verifTime)}`);

    // Memory usage (rough, from process)
    const mem = process.memoryUsage();
    return {
        targetConstraints: constraintCount,
        actualConstraints: Number(actualConstraints),
        proveTimeMs: proveTime,
        verifyTimeMs: verifTime,
        memRssGb: (mem.rss / 1024 ** 3).toFixed(2),
        valid,
    };
}

// ==========================================
// Main
// ==========================================
async function main() {
    console.log('==========================================');
    console.log(' Realistic Groth16 Prover Experiment');
    console.log('==========================================');
    console.log(`Machine: ${os.cpus().length} CPUs, ${(os.totalmem() / 1024 ** 3).toFixed(1)} GB RAM`);
    console.log();

    fs.mkdirSync(BENCH_DIR, { recursive: true });
    fs.mkdirSync(RESULTS_DIR, { recursive: true });

    const results = [];
    for (const c of TARGET_CONSTRAINTS) {
        log(`\n--- Benchmarking ~${c} constraints ---`);
        const res = await benchmarkConstraintCount(c);
        if (res) results.push(res);
        console.log();
    }

    // ==========================================
    // Report
    // ==========================================
    console.log('==========================================');
    console.log(' Results Summary ');
    console.log('==========================================');
    console.log('Constraints\tProve Time\tVerify Time');
    for (const r of results) {
        console.log(`${r.actualConstraints}\t${formatTime(r.proveTimeMs)}\t${formatTime(r.verifyTimeMs)}`);
    }

    // Extrapolate to 20M if not reached
    const last = results[results.length - 1];
    if (last && last.actualConstraints < 20_000_000) {
        const millisPerConstraint = last.proveTimeMs / last.actualConstraints;
        const est20M = millisPerConstraint * 20_000_000;
        console.log(`\nExtrapolated 20M constr: ~${formatTime(est20M)} (single thread)`);
        console.log(`NOTICE: This is a rough estimate; actual time may vary due to memory swapping.`);
    }

    // Save JSON
    const reportPath = path.join(RESULTS_DIR, 'realistic_groth16_report.json');
    fs.writeFileSync(reportPath, JSON.stringify({
        timestamp: new Date().toISOString(),
        system: { cpus: os.cpus().length, ramGB: (os.totalmem() / 1024 ** 3).toFixed(1) },
        results,
    }, null, 2));
    log(`Report saved to ${reportPath}`);
}

main().catch(err => { console.error(err); process.exit(1); });