#!/usr/bin/env node
/**
 * ==========================================
 * Kịch Bản 2: Deploy to Sepolia Testnet
 * ==========================================
 *
 * Purpose:
 *   Deploy contracts to Sepolia testnet and measure REAL gas consumption
 *   instead of theoretical calculations.
 *
 * Usage:
 *   1. Set SEPOLIA_RPC_URL in .env or environment variable
 *   2. Get testnet ETH from https://www.sepoliafaucet.io/
 *   3. Run: node scripts/deploy_sepolia.cjs
 *
 * Results:
 *   - Real gas used per contract deployment
 *   - Real gas for each transaction
 *   - Output to results/sepolia_gas_report.json
 */

const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');

// ==========================================
// Configuration
// ==========================================

const BUILD_DIR = path.join(__dirname, '..', 'build');
const RESULTS_DIR = path.join(__dirname, '..', 'results', 'sepolia');

// Load environment
function loadEnv() {
    const envPath = path.join(__dirname, '..', '.env');
    if (fs.existsSync(envPath)) {
        const envContent = fs.readFileSync(envPath, 'utf8');
        envContent.split('\n').forEach(line => {
            const [key, ...vals] = line.split('=');
            if (key && vals.length > 0) {
                process.env[key.trim()] = vals.join('=').trim();
            }
        });
    }
}

loadEnv();

// Sepolia configuration
const SEPOLIA_RPC = process.env.SEPOLIA_RPC_URL || 'https://rpc.sepolia.org';
const PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY || '0x4c0883a69102937d6231471b5dbb6204fe512961708279f22f1da1c87a3b8b4b';

// Chain ID for Sepolia
const CHAIN_ID = 11155111;

// ==========================================
// Helpers
// ==========================================

function loadContract(name) {
    const abiPath = path.join(BUILD_DIR, `${name}.abi`);
    const binPath = path.join(BUILD_DIR, `${name}.bin`);

    if (!fs.existsSync(abiPath)) {
        throw new Error(`ABI not found: ${abiPath}`);
    }
    if (!fs.existsSync(binPath)) {
        throw new Error(`BIN not found: ${binPath}`);
    }

    return {
        abi: JSON.parse(fs.readFileSync(abiPath, 'utf8')),
        bytecode: '0x' + fs.readFileSync(binPath, 'utf8').trim()
    };
}

async function deployContract(wallet, name, ...args) {
    const { abi, bytecode } = loadContract(name);
    const factory = new ethers.ContractFactory(abi, bytecode, wallet);

    console.log(`  Deploying ${name}...`);

    const startBalance = await wallet.provider.getBalance(wallet.address);
    const deployStart = Date.now();

    const contract = await factory.deploy(...args, { gasLimit: 10000000 });
    const receipt = await contract.deploymentTransaction().wait();

    const deployEnd = Date.now();
    const endBalance = await wallet.provider.getBalance(wallet.address);

    const deployTime = deployEnd - deployStart;
    const gasUsed = receipt.gasUsed;
    const gasPrice = receipt.gasPrice;
    const deployCost = gasUsed * gasPrice;

    const address = await contract.getAddress();

    console.log(`    Address: ${address}`);
    console.log(`    Gas Used: ${gasUsed.toLocaleString()}`);
    console.log(`    Gas Price: ${ethers.formatUnits(gasPrice, 'gwei')} gwei`);
    console.log(`    Deploy Cost: ${ethers.formatEther(deployCost)} ETH`);
    console.log(`    Deploy Time: ${deployTime}ms`);

    return {
        name,
        address,
        gasUsed: gasUsed.toString(),
        gasPrice: gasPrice.toString(),
        deployCostEth: ethers.formatEther(deployCost),
        deployTimeMs: deployTime,
        blockNumber: receipt.blockNumber
    };
}

async function sendTransaction(wallet, contract, method, args, value = 0) {
    console.log(`    Calling ${method}...`);

    const startBalance = await wallet.provider.getBalance(wallet.address);

    const tx = await contract[method](...args, { value, gasLimit: 5000000 });
    const receipt = await tx.wait();

    const gasUsed = receipt.gasUsed;
    const gasPrice = receipt.gasPrice;
    const txCost = gasUsed * gasPrice;

    console.log(`      Gas Used: ${gasUsed.toLocaleString()}`);
    console.log(`      Tx Cost: ${ethers.formatEther(txCost)} ETH`);

    return {
        method,
        gasUsed: gasUsed.toString(),
        gasPrice: gasPrice.toString(),
        txCostEth: ethers.formatEther(txCost),
        blockNumber: receipt.blockNumber
    };
}

// ==========================================
// Main Deployment
// ==========================================

async function main() {
    console.log('='.repeat(70));
    console.log('  Kịch Bản 2: Deploy to Sepolia Testnet');
    console.log('  Measuring REAL gas consumption on Sepolia');
    console.log('='.repeat(70));
    console.log();

    // Check for Sepolia RPC
    if (!process.env.SEPOLIA_RPC_URL) {
        console.log('WARNING: SEPOLIA_RPC_URL not set in .env');
        console.log('Using default: https://rpc.sepolia.org');
    }
    console.log(`  RPC: ${SEPOLIA_RPC}`);
    console.log();

    // Setup provider and wallet
    const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC);
    const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

    console.log(`  Deployer: ${wallet.address}`);
    console.log();

    // Check balance
    const balance = await provider.getBalance(wallet.address);
    console.log(`  Balance: ${ethers.formatEther(balance)} ETH`);
    console.log();

    if (parseFloat(ethers.formatEther(balance)) < 0.01) {
        console.log('WARNING: Balance is low. Get more testnet ETH from:');
        console.log('  https://www.sepoliafaucet.io/');
        console.log();
    }

    // Results storage
    const results = {
        network: {
            chainId: CHAIN_ID,
            rpc: SEPOLIA_RPC,
            deployer: wallet.address,
            balance: ethers.formatEther(balance),
            timestamp: new Date().toISOString()
        },
        deployments: [],
        transactions: [],
        summary: {}
    };

    // ==========================================
    // Deploy ReputationRegistry
    // ==========================================
    console.log('[1/3] Deploying ReputationRegistry...');
    console.log('  (MF-PoP reputation mechanism)');

    const repDeploy = await deployContract(wallet, 'ReputationRegistry');
    results.deployments.push(repDeploy);

    const repAddress = repDeploy.address;

    // Bootstrap deployer as updater
    const repContract = new ethers.Contract(repAddress, loadContract('ReputationRegistry').abi, wallet);
    const tx1 = await sendTransaction(wallet, repContract, 'authorizeUpdater', [wallet.address]);

    // Bootstrap register
    const tx2 = await sendTransaction(wallet, repContract, 'bootstrapRegister', [[wallet.address]]);

    results.transactions.push(tx1, tx2);
    console.log();

    // ==========================================
    // Deploy ClusterManager
    // ==========================================
    console.log('[2/3] Deploying ClusterManager...');
    console.log('  (Hierarchical clustering with VRF)');

    const clusterDeploy = await deployContract(wallet, 'ClusterManager', repAddress);
    results.deployments.push(clusterDeploy);

    const clusterAddress = clusterDeploy.address;

    // Authorize ClusterManager as updater
    const clusterContract = new ethers.Contract(clusterAddress, loadContract('ClusterManager').abi, wallet);
    const tx3 = await sendTransaction(wallet, repContract, 'authorizeUpdater', [clusterAddress]);
    results.transactions.push(tx3);
    console.log();

    // ==========================================
    // Deploy AuditContractV2
    // ==========================================
    console.log('[3/3] Deploying AuditContractV2...');
    console.log('  (Enhanced Protocol Ψ with weighted audit)');

    const auditDeploy = await deployContract(wallet, 'AuditContractV2', repAddress, clusterAddress);
    results.deployments.push(auditDeploy);

    const auditAddress = auditDeploy.address;

    const auditContract = new ethers.Contract(auditAddress, loadContract('AuditContractV2').abi, wallet);

    // Add auditor
    const tx4 = await sendTransaction(wallet, auditContract, 'addAuditor', [wallet.address]);
    results.transactions.push(tx4);

    // Fund contract via raw transfer (fallback function)
    console.log('    Funding contract...');
    const fundTx = await wallet.sendTransaction({
        to: auditAddress,
        value: ethers.parseEther('0.01')
    });
    const fundReceipt = await fundTx.wait();
    const fundResult = {
        method: 'fund',
        gasUsed: fundReceipt.gasUsed.toString(),
        gasPrice: fundReceipt.gasPrice.toString(),
        txCostEth: ethers.formatEther(fundReceipt.gasUsed * fundReceipt.gasPrice),
        blockNumber: fundReceipt.blockNumber
    };
    results.transactions.push(fundResult);
    console.log(`      Funded: ${ethers.formatEther(ethers.parseEther('0.01'))} ETH`);

    // NOTE: In production, set real Groth16 verifying key via setVerifyingKey()
    // For testing on Sepolia without real zk-SNARK, enable mock verifier:
    const tx6 = await sendTransaction(wallet, auditContract, 'enableMockVerifier', []);
    results.transactions.push(tx6);
    console.log();

    // ==========================================
    // Register chains and measure gas
    // ==========================================
    console.log('[Bonus] Registering chains and measuring gas...');
    console.log('  (10 chains for 200-node system simulation)');

    const initialRoot = ethers.keccak256(ethers.toUtf8Bytes('zkCross-v2-sepolia'));

    for (let i = 1; i <= 10; i++) {
        const chainId = CHAIN_ID * 100 + i;
        const tx = await sendTransaction(wallet, auditContract, 'registerChain', [chainId, initialRoot]);
        results.transactions.push(tx);
    }
    console.log();

    // ==========================================
    // Create cluster and measure gas
    // ==========================================
    console.log('[Bonus] Creating cluster and measuring gas...');

    const clusterChains = Array.from({length: 10}, (_, i) => CHAIN_ID * 100 + i + 1);
    const tx7 = await sendTransaction(wallet, clusterContract, 'createCluster', [clusterChains, [wallet.address]]);
    results.transactions.push(tx7);
    console.log();

    // ==========================================
    // Summary
    // ==========================================
    console.log('='.repeat(70));
    console.log('  SUMMARY: Real Gas on Sepolia');
    console.log('='.repeat(70));

    // Calculate totals
    let totalDeployGas = results.deployments.reduce((sum, d) => sum + BigInt(d.gasUsed), 0n);
    let totalTxGas = results.transactions.reduce((sum, t) => sum + BigInt(t.gasUsed), 0n);
    let totalGas = totalDeployGas + totalTxGas;

    let totalDeployCost = results.deployments.reduce((sum, d) => sum + parseFloat(d.deployCostEth), 0);
    let totalTxCost = results.transactions.reduce((sum, t) => sum + parseFloat(t.txCostEth || '0'), 0);
    let totalCost = totalDeployCost + totalTxCost;

    results.summary = {
        totalDeployGas: totalDeployGas.toString(),
        totalTxGas: totalTxGas.toString(),
        totalGas: totalGas.toString(),
        totalDeployCostEth: totalDeployCost.toFixed(6),
        totalTxCostEth: totalTxCost.toFixed(6),
        totalCostEth: totalCost.toFixed(6)
    };

    console.log();
    console.log('Deployments:');
    for (const d of results.deployments) {
        console.log(`  ${d.name}: ${parseInt(d.gasUsed).toLocaleString()} gas (${d.deployCostEth} ETH)`);
    }
    console.log();
    console.log(`  TOTAL Deployment Gas: ${totalDeployGas.toLocaleString()}`);
    console.log(`  TOTAL Deployment Cost: ${totalDeployCost.toFixed(6)} ETH`);

    console.log();
    console.log(`  TOTAL Transaction Gas: ${totalTxGas.toLocaleString()}`);
    console.log(`  TOTAL Transaction Cost: ${totalTxCost.toFixed(6)} ETH`);

    console.log();
    console.log(`  GRAND TOTAL Gas: ${totalGas.toLocaleString()}`);
    console.log(`  GRAND TOTAL Cost: ${totalCost.toFixed(6)} ETH`);

    console.log();
    console.log('Contract Addresses:');
    console.log(`  ReputationRegistry: ${repAddress}`);
    console.log(`  ClusterManager: ${clusterAddress}`);
    console.log(`  AuditContractV2: ${auditAddress}`);

    // Save results
    fs.mkdirSync(RESULTS_DIR, { recursive: true });

    const jsonPath = path.join(RESULTS_DIR, 'sepolia_gas_report.json');
    fs.writeFileSync(jsonPath, JSON.stringify(results, null, 2));
    console.log();
    console.log(`Results saved to: ${jsonPath}`);

    // Save deployment addresses
    const deploymentPath = path.join(__dirname, '..', 'deployment_sepolia.json');
    fs.writeFileSync(deploymentPath, JSON.stringify({
        network: results.network.chainId,
        contracts: {
            reputationRegistry: repAddress,
            clusterManager: clusterAddress,
            auditContractV2: auditAddress
        },
        deployedAt: results.network.timestamp
    }, null, 2));
    console.log(`Deployment addresses saved to: ${deploymentPath}`);

    console.log();
    console.log('='.repeat(70));
    console.log('  Deploy Complete!');
    console.log('='.repeat(70));

    return results;
}

main().catch(err => {
    console.error();
    console.error('ERROR:', err.message);
    if (err.message.includes('insufficient funds')) {
        console.error();
        console.error('Get testnet ETH from: https://www.sepoliafaucet.io/');
    }
    process.exit(1);
});
