#!/usr/bin/env node
/**
 * Deploy one global audit stack for the full 10 VM / 100 chain system.
 *
 * Run on VM1 or from any machine that can reach VM1's audit RPC:
 *   GLOBAL_AUDIT_RPC=http://localhost:8545 node scripts/deploy_global_audit.cjs
 */

const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

const PROJECT_DIR = path.join(__dirname, '..');
const BUILD_DIR = path.join(PROJECT_DIR, 'build');
const GLOBAL_BUILD_DIR = process.env.GLOBAL_BUILD_DIR || path.join(PROJECT_DIR, 'build_global');
const ARTIFACT_DIR = path.join(PROJECT_DIR, 'artifacts', 'contracts');
const OUT_PATH = path.join(PROJECT_DIR, 'deployment_global_audit.json');

const GLOBAL_AUDIT_RPC = process.env.GLOBAL_AUDIT_RPC || 'http://localhost:8545';
const TOTAL_VMS = parseInt(process.env.TOTAL_VMS || '10', 10);
const CHAINS_PER_VM = parseInt(process.env.CHAINS_PER_VM || '10', 10);
const CLUSTER_COUNT = parseInt(process.env.CLUSTER_COUNT || '10', 10);

const ACCOUNTS = {
  deployer: '0x4c0883a69102937d6231471b5dbb6204fe512961708279f22f1da1c87a3b8b4b',
  committer: '0x8da4ef21b864d2cc526dbdb2a120bd2874c36c9d878a2d28ebe00030e7f56e3a',
  committer2: '0x9d3678e15e73d1d279a0a6c048c42c28d8890d3bec36f14da9fe3ad7c91bb3c2',
  auditor: '0x1da6847600b0ee25e9ad9a52abbd786dd2502fa1837ab9a5b5d5b373bf24b076',
};

function loadContract(name) {
  const loadBuildOutput = (buildDir) => {
    const abiPath = path.join(buildDir, `${name}.abi`);
    const binPath = path.join(buildDir, `${name}.bin`);
    if (!fs.existsSync(abiPath) || !fs.existsSync(binPath)) {
      return null;
    }

    return {
      abi: JSON.parse(fs.readFileSync(abiPath, 'utf8')),
      bytecode: `0x${fs.readFileSync(binPath, 'utf8').trim()}`,
    };
  };

  const compatibleBuild = loadBuildOutput(GLOBAL_BUILD_DIR);
  if (compatibleBuild) {
    return compatibleBuild;
  }

  const legacyBuild = loadBuildOutput(BUILD_DIR);
  if (legacyBuild && process.env.USE_HARDHAT_ARTIFACTS !== '1') {
    return legacyBuild;
  }

  const artifactByName = {
    ReputationRegistry: path.join(ARTIFACT_DIR, 'audit_chain', 'ReputationRegistry.sol', 'ReputationRegistry.json'),
    ClusterManager: path.join(ARTIFACT_DIR, 'audit_chain', 'ClusterManager.sol', 'ClusterManager.json'),
    AuditContractV2: path.join(ARTIFACT_DIR, 'audit_chain', 'AuditContractV2.sol', 'AuditContractV2.json'),
  };
  const artifactPath = artifactByName[name];
  if (artifactPath && fs.existsSync(artifactPath)) {
    const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
    return {
      abi: artifact.abi,
      bytecode: artifact.bytecode,
    };
  }

  throw new Error(
    `Missing ${name}.abi/.bin in build_global/ or build/. Run node scripts/compile_global_compatible.cjs first.`,
  );
}

async function deploy(wallet, name, ...args) {
  const { abi, bytecode } = loadContract(name);
  const factory = new ethers.ContractFactory(abi, bytecode, wallet);
  const contract = await factory.deploy(...args);
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  console.log(`  ✓ ${name}: ${address}`);
  return { contract, address };
}

function allChainIds() {
  const ids = [];
  for (let vm = 1; vm <= TOTAL_VMS; vm++) {
    for (let chain = 1; chain <= CHAINS_PER_VM; chain++) {
      ids.push(BigInt(vm * 100 + chain));
    }
  }
  return ids;
}

function splitClusters(chainIds) {
  const clusters = Array.from({ length: CLUSTER_COUNT }, () => []);
  for (let i = 0; i < chainIds.length; i++) {
    clusters[i % CLUSTER_COUNT].push(chainIds[i]);
  }
  return clusters;
}

async function main() {
  console.log('========================================================');
  console.log('  zkCross Global Audit Deployment');
  console.log(`  RPC: ${GLOBAL_AUDIT_RPC}`);
  console.log(`  Chains: ${TOTAL_VMS * CHAINS_PER_VM}, Clusters: ${CLUSTER_COUNT}`);
  console.log('========================================================');

  const provider = new ethers.JsonRpcProvider(GLOBAL_AUDIT_RPC);
  const deployer = new ethers.Wallet(ACCOUNTS.deployer, provider);
  const auditor = new ethers.Wallet(ACCOUNTS.auditor, provider);

  const chainIds = allChainIds();
  const initialRoot = ethers.keccak256(ethers.toUtf8Bytes('zkCross-global-audit-initial-root'));

  console.log('\n[1/4] Deploying contracts...');
  const { contract: rep, address: reputationRegistry } = await deploy(deployer, 'ReputationRegistry');
  const { contract: cluster, address: clusterManager } = await deploy(deployer, 'ClusterManager', reputationRegistry);
  const { contract: audit, address: auditContractV2 } = await deploy(
    deployer,
    'AuditContractV2',
    reputationRegistry,
    clusterManager,
  );

  console.log('\n[2/4] Authorizing contracts and accounts...');
  await (await rep.authorizeUpdater(clusterManager)).wait();
  await (await rep.authorizeUpdater(auditContractV2)).wait();

  const deployerAddr = await deployer.getAddress();
  const committerAddr = new ethers.Wallet(ACCOUNTS.committer).address;
  const committer2Addr = new ethers.Wallet(ACCOUNTS.committer2).address;
  const auditorAddr = await auditor.getAddress();
  await (await rep.bootstrapRegister([deployerAddr, committerAddr, committer2Addr])).wait();
  await (await audit.addAuditor(auditorAddr)).wait();
  await (await audit.enableMockVerifier()).wait();
  await (await deployer.sendTransaction({ to: auditContractV2, value: ethers.parseEther('5') })).wait();
  await (await deployer.sendTransaction({ to: committerAddr, value: ethers.parseEther('10') })).wait();
  await (await deployer.sendTransaction({ to: committer2Addr, value: ethers.parseEther('10') })).wait();
  await (await deployer.sendTransaction({ to: auditorAddr, value: ethers.parseEther('10') })).wait();
  console.log('  ✓ Reputation updaters, auditor, mock verifier, reward fund configured');

  console.log('\n[3/4] Registering 100 ordinary chain IDs on global audit...');
  for (const chainId of chainIds) {
    await (await audit.registerChain(chainId, initialRoot)).wait();
  }
  console.log(`  ✓ Registered ${chainIds.length} chains`);

  console.log('\n[4/4] Creating global clusters...');
  const members = [deployerAddr, committerAddr, committer2Addr];
  const clusters = splitClusters(chainIds);
  for (let i = 0; i < clusters.length; i++) {
    await (await cluster.createCluster(clusters[i], members)).wait();
    console.log(`  ✓ Cluster ${i + 1}: ${clusters[i].length} chains`);
  }

  const deployment = {
    type: 'global-audit',
    deployedAt: new Date().toISOString(),
    rpc: GLOBAL_AUDIT_RPC,
    totalVms: TOTAL_VMS,
    chainsPerVm: CHAINS_PER_VM,
    totalChains: chainIds.length,
    totalNodes: chainIds.length * 2,
    clusterCount: CLUSTER_COUNT,
    reputationRegistry,
    clusterManager,
    auditContractV2,
    accounts: {
      deployer: deployerAddr,
      committer: committerAddr,
      committer2: committer2Addr,
      auditor: auditorAddr,
    },
    chainIds: chainIds.map((x) => x.toString()),
    clusters: clusters.map((ids, index) => ({
      clusterId: index + 1,
      chainIds: ids.map((x) => x.toString()),
    })),
  };

  fs.writeFileSync(OUT_PATH, JSON.stringify(deployment, null, 2));
  console.log(`\nSaved: ${OUT_PATH}`);
}

main().catch((err) => {
  console.error('\nGlobal audit deployment failed:', err);
  process.exit(1);
});
