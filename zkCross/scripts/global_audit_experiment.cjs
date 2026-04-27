#!/usr/bin/env node
/**
 * Global audit experiment for the full 100-chain / 200-node topology.
 *
 * This measures the Layer-2 global audit path:
 *   original: k chain proofs per round
 *   zkCross v2: M cluster proofs per round, M ~= sqrt(k)
 *
 * Run:
 *   GLOBAL_AUDIT_RPC=http://localhost:8545 node scripts/global_audit_experiment.cjs
 */

const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

const PROJECT_DIR = path.join(__dirname, '..');
const BUILD_DIR = path.join(PROJECT_DIR, 'build');
const DEPLOYMENT_PATH = path.join(PROJECT_DIR, 'deployment_global_audit.json');
const RESULTS_DIR = path.join(PROJECT_DIR, 'results', 'global_audit');

const GLOBAL_AUDIT_RPC = process.env.GLOBAL_AUDIT_RPC || 'http://localhost:8545';
const ROUNDS = parseInt(process.env.GLOBAL_AUDIT_ROUNDS || '5', 10);

const KEYS = {
  committer: '0x8da4ef21b864d2cc526dbdb2a120bd2874c36c9d878a2d28ebe00030e7f56e3a',
  committer2: '0x9d3678e15e73d1d279a0a6c048c42c28d8890d3bec36f14da9fe3ad7c91bb3c2',
  auditor: '0x1da6847600b0ee25e9ad9a52abbd786dd2502fa1837ab9a5b5d5b373bf24b076',
};

function loadAbi(name) {
  const abiPath = path.join(BUILD_DIR, `${name}.abi`);
  if (!fs.existsSync(abiPath)) throw new Error(`ABI not found: ${abiPath}`);
  return JSON.parse(fs.readFileSync(abiPath, 'utf8'));
}

function loadDeployment() {
  if (!fs.existsSync(DEPLOYMENT_PATH)) {
    throw new Error(`Missing ${DEPLOYMENT_PATH}. Run scripts/deploy_global_audit.cjs first.`);
  }
  return JSON.parse(fs.readFileSync(DEPLOYMENT_PATH, 'utf8'));
}

function randomRoot(label) {
  return ethers.keccak256(ethers.toUtf8Bytes(`${label}:${Date.now()}:${Math.random()}`));
}

function groupId(chainId, blockStart, blockEnd) {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ['uint256', 'uint256', 'uint256'],
      [BigInt(chainId), BigInt(blockStart), BigInt(blockEnd)],
    ),
  );
}

function ms(start) {
  return Date.now() - start;
}

function avg(values) {
  if (values.length === 0) return 0;
  return values.reduce((a, b) => a + b, 0) / values.length;
}

async function ensureStake(auditAsCommitter, walletName) {
  const minStake = ethers.parseEther('1');
  const stake = await auditAsCommitter.committerStakes(auditAsCommitter.runner.address);
  if (stake < minStake) {
    console.log(`  Staking ${walletName} on global audit...`);
    await (await auditAsCommitter.stake({ value: minStake })).wait();
  }
}

async function submitGlobalProof(auditAsCommitter, auditAsAuditor, chainId, round, clusterId) {
  const blockStart = round * 1000 + clusterId * 10;
  const blockEnd = blockStart + 9;
  const oldRoot = await auditAsAuditor.getChainRoot(chainId);
  const newRoot = randomRoot(`global:${round}:${clusterId}:${chainId}`);
  const gid = groupId(chainId, blockStart, blockEnd);

  const submitStart = Date.now();
  const submitTx = await auditAsCommitter.submitCommit(chainId, oldRoot, newRoot, blockStart, blockEnd);
  const submitReceipt = await submitTx.wait();
  const submitLatencyMs = ms(submitStart);

  const proofA = [0n, 0n];
  const proofB = [[0n, 0n], [0n, 0n]];
  const proofC = [0n, 0n];

  const acceptStart = Date.now();
  const acceptTx = await auditAsAuditor.weightedAuditAccept(gid, chainId, proofA, proofB, proofC);
  const acceptReceipt = await acceptTx.wait();
  const acceptLatencyMs = ms(acceptStart);

  return {
    chainId: chainId.toString(),
    clusterId,
    submitGas: submitReceipt.gasUsed.toString(),
    acceptGas: acceptReceipt.gasUsed.toString(),
    submitLatencyMs,
    acceptLatencyMs,
    totalLatencyMs: submitLatencyMs + acceptLatencyMs,
    submitTx: submitReceipt.hash,
    acceptTx: acceptReceipt.hash,
  };
}

async function main() {
  const deployment = loadDeployment();
  fs.mkdirSync(RESULTS_DIR, { recursive: true });

  const provider = new ethers.JsonRpcProvider(GLOBAL_AUDIT_RPC);
  const committer = new ethers.Wallet(KEYS.committer, provider);
  const committer2 = new ethers.Wallet(KEYS.committer2, provider);
  const auditor = new ethers.Wallet(KEYS.auditor, provider);

  const auditAbi = loadAbi('AuditContractV2');
  const auditAsCommitter = new ethers.Contract(deployment.auditContractV2, auditAbi, committer);
  const auditAsCommitter2 = new ethers.Contract(deployment.auditContractV2, auditAbi, committer2);
  const auditAsAuditor = new ethers.Contract(deployment.auditContractV2, auditAbi, auditor);

  const totalChains = deployment.chainIds.length;
  const clusters = deployment.clusters;
  const clusterCount = clusters.length;
  const totalNodes = totalChains * 2;

  console.log('========================================================');
  console.log('  zkCross Global Audit Experiment');
  console.log(`  RPC: ${GLOBAL_AUDIT_RPC}`);
  console.log(`  Chains: ${totalChains}, Nodes: ${totalNodes}, Clusters: ${clusterCount}`);
  console.log(`  Rounds: ${ROUNDS}`);
  console.log('========================================================');

  await ensureStake(auditAsCommitter, 'committer1');
  await ensureStake(auditAsCommitter2, 'committer2');

  const rounds = [];

  for (let round = 1; round <= ROUNDS; round++) {
    console.log(`\n[Round ${round}/${ROUNDS}] Global audit with ${clusterCount} cluster proofs...`);
    const roundStart = Date.now();
    const proofResults = [];

    for (const cluster of clusters) {
      const clusterId = cluster.clusterId;
      const representativeChainId = BigInt(cluster.chainIds[0]);
      const submitter = clusterId % 2 === 0 ? auditAsCommitter2 : auditAsCommitter;
      const result = await submitGlobalProof(
        submitter,
        auditAsAuditor,
        representativeChainId,
        round,
        clusterId,
      );
      proofResults.push(result);
      console.log(
        `  Cluster ${clusterId}: chain ${result.chainId}, ` +
        `submit ${result.submitGas} gas, accept ${result.acceptGas} gas, ` +
        `${result.totalLatencyMs}ms`,
      );
    }

    const roundLatencyMs = ms(roundStart);
    const submitGasTotal = proofResults.reduce((sum, r) => sum + BigInt(r.submitGas), 0n);
    const acceptGasTotal = proofResults.reduce((sum, r) => sum + BigInt(r.acceptGas), 0n);
    const totalGas = submitGasTotal + acceptGasTotal;
    const throughputProofsPerSec = clusterCount / (roundLatencyMs / 1000);

    const summary = {
      round,
      originalProofsPerRound: totalChains,
      globalProofsPerRound: clusterCount,
      reductionFactor: totalChains / clusterCount,
      roundLatencyMs,
      throughputProofsPerSec,
      submitGasTotal: submitGasTotal.toString(),
      acceptGasTotal: acceptGasTotal.toString(),
      totalGas: totalGas.toString(),
      avgProofLatencyMs: avg(proofResults.map((r) => r.totalLatencyMs)),
      proofs: proofResults,
    };

    rounds.push(summary);
    console.log(
      `  Round ${round} summary: ${roundLatencyMs}ms, ` +
      `${throughputProofsPerSec.toFixed(2)} proofs/s, gas=${totalGas}`,
    );
  }

  const aggregate = {
    avgRoundLatencyMs: avg(rounds.map((r) => r.roundLatencyMs)),
    avgThroughputProofsPerSec: avg(rounds.map((r) => r.throughputProofsPerSec)),
    avgTotalGasPerRound: Math.round(avg(rounds.map((r) => Number(r.totalGas)))),
    reductionFactor: totalChains / clusterCount,
  };

  const report = {
    experiment: 'global_audit',
    description: 'One global audit chain measuring O(k) vs O(sqrt(k)) audit workload for 100 chains / 200 nodes',
    measuredAt: new Date().toISOString(),
    deployment: {
      auditContractV2: deployment.auditContractV2,
      reputationRegistry: deployment.reputationRegistry,
      clusterManager: deployment.clusterManager,
      rpc: GLOBAL_AUDIT_RPC,
    },
    topology: {
      totalVms: deployment.totalVms,
      chainsPerVm: deployment.chainsPerVm,
      totalChains,
      totalNodes,
      clusterCount,
    },
    aggregate,
    rounds,
  };

  const jsonPath = path.join(RESULTS_DIR, 'global_audit_report.json');
  fs.writeFileSync(jsonPath, JSON.stringify(report, null, 2));

  const csvPath = path.join(RESULTS_DIR, 'global_audit_rounds.csv');
  fs.writeFileSync(
    csvPath,
    [
      'round,original_proofs,global_proofs,reduction_factor,round_latency_ms,throughput_proofs_per_sec,submit_gas,accept_gas,total_gas,avg_proof_latency_ms',
      ...rounds.map((r) => [
        r.round,
        r.originalProofsPerRound,
        r.globalProofsPerRound,
        r.reductionFactor.toFixed(2),
        r.roundLatencyMs,
        r.throughputProofsPerSec.toFixed(4),
        r.submitGasTotal,
        r.acceptGasTotal,
        r.totalGas,
        r.avgProofLatencyMs.toFixed(2),
      ].join(',')),
    ].join('\n'),
  );

  console.log('\n========================================================');
  console.log('  GLOBAL AUDIT COMPLETE');
  console.log('========================================================');
  console.log(`  Reduction: ${aggregate.reductionFactor.toFixed(2)}x`);
  console.log(`  Avg round latency: ${aggregate.avgRoundLatencyMs.toFixed(0)}ms`);
  console.log(`  Avg throughput: ${aggregate.avgThroughputProofsPerSec.toFixed(2)} proofs/s`);
  console.log(`  Avg gas/round: ${aggregate.avgTotalGasPerRound}`);
  console.log(`  JSON: ${jsonPath}`);
  console.log(`  CSV:  ${csvPath}`);
}

main().catch((err) => {
  console.error('\nGlobal audit experiment failed:', err);
  process.exit(1);
});
