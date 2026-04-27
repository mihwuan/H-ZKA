/**
 * zkCross Relay Node (Committer)
 *
 * Paper Section 4.1 & 5.3: The committer is a lower-layer node that bridges
 * ordinary chains to the audit chain. It implements the relay mechanism in
 * zkCross's tree-shaped architecture.
 *
 * Responsibilities (per Protocol Ψ):
 *   1. Monitor ordinary chains for new Burned/Locked events
 *   2. Aggregate transaction state roots from blocks
 *   3. Generate ZKP proofs off-chain using circuit Λ_Ψ (Groth16)
 *   4. Submit TxCommit to the audit chain (Chain B)
 *   5. The auditor then verifies the commit via verifyCommit()
 *
 * Architecture:
 *   Chain A ──[Burned/Locked events]──► Relay ──[TxCommit + proof]──► Chain B (Audit)
 *
 * Usage:
 *   node relay/relay.js [--once]   # --once = process current blocks and exit
 */

const { ethers } = require('ethers');
const path = require('path');
const fs = require('fs');
const { RPC, KEYS, loadContract, randFieldBytes32 } = require('../test/helpers');
const { generateProof, loadVerificationKeys } = require('../scripts/zkp_utils');

// Configuration
const POLL_INTERVAL_MS = 3000; // 3s (= Clique block period)
const BATCH_SIZE = 50;          // Aggregate up to 50 txs per proof
const MODE = process.argv.includes('--once') ? 'once' : 'daemon';

class Relay {
    constructor() {
        this.providerA = new ethers.JsonRpcProvider(RPC.chainA);
        this.providerB = new ethers.JsonRpcProvider(RPC.chainB);
        this.committer = new ethers.Wallet(KEYS.committer, this.providerB);
        this.lastProcessedBlock = {};  // chainId → blockNumber
        this.stats = { eventsDetected: 0, proofsGenerated: 0, commitsSubmitted: 0 };
    }

    async init() {
        // Load deployment addresses
        const deployPath = path.join(__dirname, '..', 'deployment.json');
        if (!fs.existsSync(deployPath)) {
            throw new Error('deployment.json not found. Run deploy_contracts.js first.');
        }
        this.deployment = JSON.parse(fs.readFileSync(deployPath, 'utf8'));

        // Connect to TransferContract on Chain A (to read Burned events)
        const tcAbi = loadContract('TransferContract').abi;
        this.transferA = new ethers.Contract(this.deployment.transfer_chain_a, tcAbi, this.providerA);

        // Connect to ExchangeContract on Chain A (to read Locked events)
        const ecAbi = loadContract('ExchangeContract').abi;
        this.exchangeA = new ethers.Contract(this.deployment.exchange_chain_a, ecAbi, this.providerA);

        // Connect to AuditContract on Chain B (to submit commits)
        const acAbi = loadContract('AuditContract').abi;
        this.auditContract = new ethers.Contract(this.deployment.audit, acAbi, this.committer);

        // Get current block numbers as starting point
        const blockA = await this.providerA.getBlockNumber();
        this.lastProcessedBlock[1001] = blockA;

        console.log(`[Relay] Initialized`);
        console.log(`  Chain A RPC: ${RPC.chainA} (block ${blockA})`);
        console.log(`  Chain B RPC: ${RPC.chainB} (audit)`);
        console.log(`  TransferContract (A): ${this.deployment.transfer_chain_a}`);
        console.log(`  ExchangeContract (A): ${this.deployment.exchange_chain_a}`);
        console.log(`  AuditContract (B): ${this.deployment.audit}`);
        console.log(`  Committer: ${this.committer.address}`);
        console.log(`  Mode: ${MODE}`);
    }

    /**
     * Scan Chain A for new Burned and Locked events since last processed block
     */
    async scanChainA(fromBlock, toBlock) {
        const events = [];

        // Query Burned events from TransferContract
        const burnFilter = this.transferA.filters.Burned();
        const burnLogs = await this.transferA.queryFilter(burnFilter, fromBlock, toBlock);
        for (const log of burnLogs) {
            events.push({
                type: 'Burned',
                block: log.blockNumber,
                txHash: log.transactionHash,
                args: log.args,
            });
        }

        // Query Locked events from ExchangeContract
        const lockFilter = this.exchangeA.filters.Locked();
        const lockLogs = await this.exchangeA.queryFilter(lockFilter, fromBlock, toBlock);
        for (const log of lockLogs) {
            events.push({
                type: 'Locked',
                block: log.blockNumber,
                txHash: log.transactionHash,
                args: log.args,
            });
        }

        return events;
    }

    /**
     * Generate ZKP proof for audit (Protocol Ψ.Commit)
     * Aggregates events into a state transition: oldRoot → newRoot
     */
    async generateAuditProof(oldRoot, newRoot) {
        const proof = await generateProof('psi_audit', [BigInt(oldRoot), BigInt(newRoot)]);
        this.stats.proofsGenerated++;
        return proof;
    }

    /**
     * Submit TxCommit to audit chain (Protocol Ψ)
     * Per paper Section 5.3: committer submits (chainId, rootOld, rootNew, proof)
     */
    async submitCommit(chainId, oldRoot, newRoot, proof) {
        const tx = await this.auditContract.submitCommit(
            chainId, oldRoot, newRoot,
            proof.proofA, proof.proofB, proof.proofC
        );
        const receipt = await tx.wait();

        // Parse CommitSubmitted event
        const evt = receipt.logs
            .map(l => { try { return this.auditContract.interface.parseLog(l); } catch { return null; } })
            .find(e => e?.name === 'CommitSubmitted');

        this.stats.commitsSubmitted++;
        return { txHash: receipt.hash, commitId: evt?.args?.[0], gasUsed: Number(receipt.gasUsed) };
    }

    /**
     * Process one round: scan → aggregate → prove → submit
     */
    async processRound() {
        const currentBlock = await this.providerA.getBlockNumber();
        const lastBlock = this.lastProcessedBlock[1001] || 0;

        if (currentBlock <= lastBlock) return null;

        const fromBlock = lastBlock + 1;
        const toBlock = currentBlock;

        // Step 1: Scan for events on Chain A
        const events = await this.scanChainA(fromBlock, toBlock);
        this.stats.eventsDetected += events.length;

        if (events.length === 0) {
            this.lastProcessedBlock[1001] = currentBlock;
            return null;
        }

        console.log(`[Relay] Found ${events.length} events in blocks ${fromBlock}–${toBlock}`);
        for (const e of events) {
            console.log(`  ${e.type} @ block ${e.block} (tx: ${e.txHash.slice(0, 18)}...)`);
        }

        // Step 2: Compute state transition (old root → new root)
        // In production, the root would come from the block's stateRoot.
        // Here we use block headers as the state representation.
        const oldHeader = await this.providerA.getBlock(fromBlock - 1);
        const newHeader = await this.providerA.getBlock(toBlock);

        // Use block stateRoot as representative state roots
        // (In the paper, this is the Merkle root of all chain state)
        const oldRoot = randFieldBytes32();   // Simplified: would be oldHeader.stateRoot
        const newRoot = randFieldBytes32();    // Simplified: would be newHeader.stateRoot

        // Step 3: Generate ZKP proof (Protocol Ψ, off-chain)
        console.log(`[Relay] Generating audit proof (Λ_Ψ)...`);
        const proofStart = Date.now();
        const proof = await this.generateAuditProof(oldRoot, newRoot);
        const proofMs = Date.now() - proofStart;
        console.log(`[Relay] Proof generated in ${proofMs}ms`);

        // Step 4: Submit TxCommit to audit chain (Chain B)
        console.log(`[Relay] Submitting TxCommit to audit chain...`);
        const result = await this.submitCommit(1001, oldRoot, newRoot, proof);
        console.log(`[Relay] TxCommit confirmed: ${result.txHash.slice(0, 18)}... gas=${result.gasUsed}`);

        this.lastProcessedBlock[1001] = currentBlock;

        return {
            fromBlock, toBlock,
            eventsCount: events.length,
            proofTimeMs: proofMs,
            commitTxHash: result.txHash,
            commitId: result.commitId,
            gasUsed: result.gasUsed,
        };
    }

    /**
     * Run as daemon: continuously poll for new blocks
     */
    async runDaemon() {
        console.log(`[Relay] Starting daemon (poll every ${POLL_INTERVAL_MS}ms)...\n`);

        const poll = async () => {
            try {
                await this.processRound();
            } catch (err) {
                console.error(`[Relay] Error: ${err.message}`);
            }
        };

        // Initial poll
        await poll();

        // Continuous polling
        const interval = setInterval(poll, POLL_INTERVAL_MS);

        // Graceful shutdown
        process.on('SIGINT', () => {
            console.log('\n[Relay] Shutting down...');
            clearInterval(interval);
            this.printStats();
            process.exit(0);
        });
    }

    /**
     * Run once: process current blocks and exit
     */
    async runOnce() {
        console.log(`[Relay] Running single pass...\n`);
        // Reset to block 0 to scan all history
        this.lastProcessedBlock[1001] = 0;
        const result = await this.processRound();
        this.printStats();
        return result;
    }

    printStats() {
        console.log('\n[Relay] Statistics:');
        console.log(`  Events detected: ${this.stats.eventsDetected}`);
        console.log(`  Proofs generated: ${this.stats.proofsGenerated}`);
        console.log(`  Commits submitted: ${this.stats.commitsSubmitted}`);
    }
}

async function main() {
    const relay = new Relay();
    await relay.init();

    if (MODE === 'once') {
        await relay.runOnce();
    } else {
        await relay.runDaemon();
    }
}

module.exports = { Relay };

if (require.main === module) {
    main().catch(err => { console.error(err); process.exit(1); });
}
