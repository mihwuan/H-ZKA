/**
 * zkCross v2 - Deploy Contracts (MF-PoP + Hierarchical Clustering)
 *
 * Deploys to 10-chain Docker testnet across 2 VMs:
 *   - 10 ordinary chains (chainIds 101-110 or 201-210)
 *   - 1 audit chain (chainId 101 or 201, using RPC port 8545)
 *
 * Contracts deployed:
 *   1. ReputationRegistry  — MF-PoP dynamic reputation
 *   2. ClusterManager      — Hierarchical clustering (O(√k) workload)
 *   3. AuditContractV2     — Enhanced Protocol Ψ with weighted audit
 *
 * Usage: node scripts/deploy_contracts_v2.js
 */

const { ethers } = require('ethers');
const fs         = require('fs');
const path       = require('path');

// ==========================================
// Configuration — 10 chains × 2 nodes per VM
// Port mapping (each chain = 2 ports, node1 odd port, node2 even port):
//   Chain 1:  8545 (n1), 8546 (n2)   → chainId 101/201
//   Chain 2:  8547 (n1), 8548 (n2)   → chainId 102/202
//   Chain 3:  8549 (n1), 8550 (n2)   → chainId 103/203
//   Chain 4:  8551 (n1), 8552 (n2)   → chainId 104/204
//   Chain 5:  8553 (n1), 8554 (n2)   → chainId 105/205
//   Chain 6:  8555 (n1), 8556 (n2)   → chainId 106/206
//   Chain 7:  8557 (n1), 8558 (n2)   → chainId 107/207
//   Chain 8:  8559 (n1), 8560 (n2)   → chainId 108/208
//   Chain 9:  8561 (n1), 8562 (n2)   → chainId 109/209
//   Chain 10: 8563 (n1), 8564 (n2)   → chainId 110/210
// ==========================================
const BUILD_DIR = path.join(__dirname, '..', 'build');

// Detect VM from environment or default to VM1 (chainIds 101-110)
const VM_ID = parseInt(process.env.VM_ID || '1');
const CHAIN_ID_BASE = VM_ID * 100;

// Build 10 chains array (ordinary chains for clustering)
const CHAINS = {
    audit: { rpc: 'http://localhost:8545', chainId: CHAIN_ID_BASE + 1, name: `Audit Chain (${CHAIN_ID_BASE + 1})` },
};

// Ordinary chains (first 9 for clustering, chain 10 reserved)
for (let i = 1; i <= 10; i++) {
    const port = 8545 + (i - 1) * 2;  // 8545, 8547, 8549, ...
    CHAINS[`chain_${i}`] = {
        rpc: `http://localhost:${port}`,
        chainId: CHAIN_ID_BASE + i,
        name: `Chain ${i} (${CHAIN_ID_BASE + i})`
    };
}

// Test accounts (funded in docker testnet genesis)
const ACCOUNTS = {
    deployer:  '0x4c0883a69102937d6231471b5dbb6204fe512961708279f22f1da1c87a3b8b4b',
    committer: '0x8da4ef21b864d2cc526dbdb2a120bd2874c36c9d878a2d28ebe00030e7f56e3a',
    committer2:'0x9d3678e15e73d1d279a0a6c048c42c28d8890d3bec36f14da9fe3ad7c91bb3c2',
    auditor:   '0x1da6847600b0ee25e9ad9a52abbd786dd2502fa1837ab9a5b5d5b373bf24b076',
};

// ==========================================
// Helpers
// ==========================================
function loadContract(name) {
    const abiPath = path.join(BUILD_DIR, `${name}.abi`);
    const binPath = path.join(BUILD_DIR, `${name}.bin`);
    if (!fs.existsSync(abiPath)) throw new Error(`ABI not found: ${abiPath}. Run: node scripts/compile_contracts_v2.js`);
    const abi      = JSON.parse(fs.readFileSync(abiPath, 'utf8'));
    const bytecode = '0x' + fs.readFileSync(binPath, 'utf8').trim();
    return { abi, bytecode };
}

function getSigner(rpcUrl, privateKey) {
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    return new ethers.Wallet(privateKey, provider);
}

async function deploy(wallet, contractName, ...args) {
    const { abi, bytecode } = loadContract(contractName);
    const factory  = new ethers.ContractFactory(abi, bytecode, wallet);
    const contract = await factory.deploy(...args);
    await contract.waitForDeployment();
    const address  = await contract.getAddress();
    console.log(`  ✓ ${contractName} deployed: ${address}`);
    return { contract, address };
}

// ==========================================
// Main
// ==========================================
async function main() {
    console.log('==============================================');
    console.log(`  zkCross v2 — Contract Deployment (VM${VM_ID})`);
    console.log('  MF-PoP + Hierarchical Clustering');
    console.log('  10 chains × 2 nodes per VM');
    console.log('==============================================\n');

    // Check testnet connectivity
    console.log('[0] Checking testnet connectivity...');
    for (const [key, chain] of Object.entries(CHAINS)) {
        if (key === 'audit') continue;
        const provider = new ethers.JsonRpcProvider(chain.rpc);
        try {
            const block = await provider.getBlockNumber();
            console.log(`  ✓ ${chain.name} (${chain.rpc}): block #${block}`);
        } catch (e) {
            throw new Error(`${chain.name} not responding at ${chain.rpc}. Start testnet first: docker compose up -d`);
        }
    }

    const auditWallet     = getSigner(CHAINS.audit.rpc, ACCOUNTS.deployer);
    const committerWallet = getSigner(CHAINS.audit.rpc, ACCOUNTS.committer);
    const committer2Wallet= getSigner(CHAINS.audit.rpc, ACCOUNTS.committer2);
    const auditorWallet   = getSigner(CHAINS.audit.rpc, ACCOUNTS.auditor);

    const initialRoot = ethers.keccak256(ethers.toUtf8Bytes('zkCross-v2-initial-state-root'));

    const deployment = {};

    // ==========================================
    // Step 1: Deploy ReputationRegistry
    // Reference: EdgeTrust-Shard JSA 2026 §3.2 (MF-PoP mechanism)
    // Addresses zkCross §4.1 gap: "at least one honest committer" assumption
    // ==========================================
    console.log('\n[1/3] Deploying ReputationRegistry (MF-PoP)...');
    console.log('      Gap addressed: zkCross §4.1 — no committer trust enforcement');
    console.log('      Fix from: EdgeTrust-Shard JSA 2026 §3.2 — R^(t+1) = clip((1-β)R + βQ)');

    const { contract: repContract, address: repAddr } = await deploy(auditWallet, 'ReputationRegistry');
    deployment.reputationRegistry = repAddr;

    // Bootstrap reputation: authorize deployer as updater
    // In production, ClusterManager would be the sole updater
    const txUpd = await repContract.authorizeUpdater(await auditWallet.getAddress());
    await txUpd.wait();
    console.log('  ✓ Deployer authorized as reputation updater');

    // Register genesis committers (bootstrap: no endorsors needed for first 2)
    // Normal registration requires 2 endorsors with R≥0.7 — for testnet we bypass via owner
    const deployerAddr   = await auditWallet.getAddress();
    const committerAddr  = await committerWallet.getAddress();
    const committer2Addr = await committer2Wallet.getAddress();

    const txBootstrap = await repContract.bootstrapRegister([deployerAddr, committerAddr, committer2Addr]);
    await txBootstrap.wait();
    console.log(`  ✓ Bootstrap-registered 3 genesis committers`);

    // ==========================================
    // Step 2: Deploy ClusterManager
    // Reference: EdgeTrust-Shard JSA 2026 §4 (Hierarchical Cluster Architecture)
    // Addresses zkCross §3.2/§7.2.2 gap: flat O(k) audit workload
    // ==========================================
    console.log('\n[2/3] Deploying ClusterManager (Hierarchical Clustering)...');
    console.log('      Gap addressed: zkCross §3.2 — O(k) audit workload per node');
    console.log('      Fix from: EdgeTrust-Shard JSA 2026 §4 — O(√k) via M=√k clusters');

    const { contract: clusterContract, address: clusterAddr } = await deploy(auditWallet, 'ClusterManager', repAddr);
    deployment.clusterManager = clusterAddr;

    // Authorize ClusterManager to update reputations
    const txAuth = await repContract.authorizeUpdater(clusterAddr);
    await txAuth.wait();
    console.log('  ✓ ClusterManager authorized as reputation updater');

    // Create M=ceil(sqrt(k)) clusters for proper O(sqrt(k)) architecture
    // For k=10 chains: M = ceil(sqrt(10)) = 4 clusters
    // Each cluster gets 2-3 chains in round-robin fashion
    const k = 10;
    const M = Math.ceil(Math.sqrt(k));
    console.log(`  Creating ${M} clusters for k=${k} chains (O(sqrt(k)) architecture)`);

    const allChainIds = [];
    for (let i = 1; i <= k; i++) {
        allChainIds.push(BigInt(CHAINS[`chain_${i}`].chainId));
    }

    // Distribute chains to M clusters in round-robin
    const clusterChainsList = [];
    for (let m = 0; m < M; m++) {
        clusterChainsList.push([]);
    }
    for (let c = 0; c < k; c++) {
        clusterChainsList[c % M].push(allChainIds[c]);
    }

    // Create clusters with committer members
    const allMembers = [deployerAddr, committerAddr, committer2Addr];
    for (let m = 0; m < M; m++) {
        const chains = clusterChainsList[m];
        const members = allMembers;  // All committers participate in all clusters
        const txCluster = await clusterContract.createCluster(chains, members);
        await txCluster.wait();
        console.log(`  ✓ Cluster ${m + 1}: ${chains.length} chains, ${members.length} members (chains: ${chains.map(c => c.toString()).join(', ')})`);
    }

    // Cluster head was elected at creation time by createCluster → _electClusterHead (internal)
    // External re-election requires 10 rounds cooldown; skip here and just read the elected head
    const headAddr = await clusterContract.getClusterHead(1n);
    console.log(`  ✓ Cluster head elected at creation (quadratic VRF): ${headAddr}`);

    // ==========================================
    // Step 3: Deploy AuditContractV2
    // Reference: zkCross §5.3 (Protocol Ψ) + improvement doc §1.3.4 (Ψ.WeightedAudit)
    // ==========================================
    console.log('\n[3/3] Deploying AuditContractV2 (Enhanced Protocol Ψ)...');
    console.log('      Integrates: MF-PoP weighted verification + O(√k) cluster path');

    const { contract: v2Contract, address: v2Addr } = await deploy(auditWallet, 'AuditContractV2', repAddr, clusterAddr);
    deployment.auditContractV2 = v2Addr;

    // Register all 10 ordinary chains on AuditContractV2
    console.log('  Registering ordinary chains...');
    for (let i = 1; i <= 10; i++) {
        const chain = CHAINS[`chain_${i}`];
        const tx = await v2Contract.registerChain(BigInt(chain.chainId), initialRoot);
        await tx.wait();
        console.log(`  ✓ ${chain.name} (ID: ${chain.chainId}) registered at ${chain.rpc}`);
    }

    // Register auditor
    const txAuditor = await v2Contract.addAuditor(await auditorWallet.getAddress());
    await txAuditor.wait();
    console.log(`  ✓ Auditor registered: ${await auditorWallet.getAddress()}`);

    // Enable mock verifier for testing (skip actual ZKP verification)
    // BUG B4 FIX: In production, set real Groth16 VK instead via setVerifyingKey()
    const txMock = await v2Contract.enableMockVerifier();
    await txMock.wait();
    console.log('  ✓ Mock verifier enabled (for testing without real zk-SNARK)');
    const txFund = await auditWallet.sendTransaction({
        to: v2Addr,
        value: ethers.parseEther('1.0')
    });
    await txFund.wait();
    console.log(`  ✓ Funded AuditContractV2 with 1.0 ETH for commit rewards`);

    // ==========================================
    // Complexity info (for gap analysis)
    // ==========================================
    const [clusterCount, proofPerAuditor, reduction] = await clusterContract.getComplexityInfo(100n);
    console.log(`\n  Complexity analysis (k=100 chains):`);
    console.log(`    Clusters (M=√k):       ${clusterCount}`);
    console.log(`    Proofs/round (v2):      O(${proofPerAuditor}) vs O(100) original`);
    console.log(`    Reduction factor:       ${reduction}×`);

    // ==========================================
    // Save deployment
    // ==========================================
    deployment.deployedAt     = new Date().toISOString();
    deployment.vmId           = VM_ID;
    deployment.auditChainRpc  = CHAINS.audit.rpc;
    deployment.auditChainId   = CHAINS.audit.chainId;
    deployment.chainCount     = 10;
    deployment.accounts       = {
        deployer:   deployerAddr,
        committer:  committerAddr,
        committer2: committer2Addr,
        auditor:    await auditorWallet.getAddress()
    };

    const outPath = path.join(__dirname, '..', 'deployment_v2.json');
    fs.writeFileSync(outPath, JSON.stringify(deployment, null, 2));

    console.log('\n==============================================');
    console.log('  zkCross v2 Deployment Complete!');
    console.log('==============================================');
    console.log(`\n  ReputationRegistry: ${repAddr}`);
    console.log(`  ClusterManager:     ${clusterAddr}`);
    console.log(`  AuditContractV2:    ${v2Addr}`);
    console.log(`\n  Addresses saved to: deployment_v2.json`);
    console.log('\n  Next: node scripts/real_workload_experiment.cjs');
}

main().catch(e => {
    console.error('\n  Deployment failed:', e.message);
    process.exit(1);
});
