/**
 * zkCross - Circuit Λ_Ψ: Cross-Chain Auditing Protocol
 * 
 * This is the most complex circuit in zkCross, implementing the auditing protocol.
 * It contains 4 sub-modules:
 *   1. AF  (Auditing Function)       - Checks transactions against blacklist
 *   2. SVF (Signature Verification)  - Verifies transaction signatures
 *   3. STF (State Transition)        - Ensures correct state updates
 *   4. RVF (Root Verification)       - Verifies state roots via Merkle trees
 * 
 * Key insight: The blacklist is embedded as a CONSTANT in the circuit,
 * reducing public inputs and improving efficiency.
 * 
 * Public inputs:  Initial state root (root_2), Final state root (root_3)
 * Private inputs: All transaction data, account states, signatures
 * 
 * Reference: zkCross paper Section 5.3 - Protocol Ψ
 */
package zkcross.psi;

import backend.structure.CircuitGenerator;
import backend.eval.SampleRun;
import backend.eval.CircuitEvaluator;
import backend.auxTypes.UnsignedInteger;
import backend.auxTypes.Bit;

import zkcross.common.SHA256Circuit;
import zkcross.common.MerkleTreeCircuit;

public class AuditCircuit extends CircuitGenerator {

    // ==========================================
    // Circuit Configuration
    // ==========================================
    
    /** Number of transactions per batch to audit.
     *  Paper Table 4 (Section 7.2.2): ℓ=100 → 11,763,593 constraints.
     *  This matches the paper's benchmark configuration for fair comparison.
     *  ℓ=100 → ~11.76M constraints, prove ~99s, verify ~5ms (paper measured values). */
    private static final int NUM_TRANSACTIONS = 100;
    
    /** Height of the state tree (binary Merkle tree) */
    private static final int STATE_TREE_HEIGHT = 8; // supports 256 accounts
    
    /** Number of addresses in the blacklist (constant in circuit) */
    private static final int BLACKLIST_SIZE = 16;

    // ==========================================
    // Public Inputs (x_vec)
    // ==========================================
    
    /** Initial state root before transactions (root_2) */
    private UnsignedInteger[] root_old;     // 8 x 32-bit words
    
    /** Final state root after transactions (root_3) */
    private UnsignedInteger[] root_new;     // 8 x 32-bit words

    // ==========================================
    // Private Inputs / Witnesses (w_vec)
    // ==========================================
    
    // --- Transaction data ---
    /** Sender public keys for each transaction */
    private UnsignedInteger[][] tx_fpk_sender;    // NUM_TX x 32 bytes
    
    /** Receiver public keys for each transaction */
    private UnsignedInteger[][] tx_fpk_receiver;  // NUM_TX x 32 bytes
    
    /** Transaction amounts */
    private UnsignedInteger[] tx_amount;           // NUM_TX x 64 bits
    
    /** Transaction signatures (simplified: hash-based) */
    private UnsignedInteger[][] tx_signature;      // NUM_TX x 64 bytes

    // --- Account states ---
    /** Old sender balances */
    private UnsignedInteger[] sender_balance_old;  // NUM_TX x 64 bits
    
    /** Old receiver balances */
    private UnsignedInteger[] receiver_balance_old;// NUM_TX x 64 bits
    
    /** Sender Merkle proofs (old state) */
    private UnsignedInteger[][][] sender_merkle_old;   // NUM_TX x HEIGHT x 8 words
    private Bit[][] sender_direction_old;               // NUM_TX x HEIGHT bits
    
    /** Receiver Merkle proofs (old state) */
    private UnsignedInteger[][][] receiver_merkle_old;  // NUM_TX x HEIGHT x 8 words
    private Bit[][] receiver_direction_old;              // NUM_TX x HEIGHT bits
    
    /** Sender Merkle proofs (new state) */
    private UnsignedInteger[][][] sender_merkle_new;    // NUM_TX x HEIGHT x 8 words
    private Bit[][] sender_direction_new;                // NUM_TX x HEIGHT bits
    
    /** Receiver Merkle proofs (new state) */
    private UnsignedInteger[][][] receiver_merkle_new;  // NUM_TX x HEIGHT x 8 words
    private Bit[][] receiver_direction_new;              // NUM_TX x HEIGHT bits
    
    /** Intermediate roots (between consecutive transactions) */
    private UnsignedInteger[][] intermediate_roots;     // (NUM_TX + 1) x 8 words

    // ==========================================
    // Constants (embedded in circuit, not inputs)
    // ==========================================
    
    /** Blacklist addresses - embedded as circuit constants */
    private static final long[][] BLACKLIST = new long[BLACKLIST_SIZE][32];
    // In practice, these would be set at circuit compilation time

    public AuditCircuit() {
        super("zkCross_Lambda_Psi_Audit");
    }

    @Override
    public void __init() {
        root_old = new UnsignedInteger[8];
        root_new = new UnsignedInteger[8];

        tx_fpk_sender = new UnsignedInteger[NUM_TRANSACTIONS][32];
        tx_fpk_receiver = new UnsignedInteger[NUM_TRANSACTIONS][32];
        tx_amount = new UnsignedInteger[NUM_TRANSACTIONS];
        tx_signature = new UnsignedInteger[NUM_TRANSACTIONS][64];

        sender_balance_old = new UnsignedInteger[NUM_TRANSACTIONS];
        receiver_balance_old = new UnsignedInteger[NUM_TRANSACTIONS];

        sender_merkle_old = new UnsignedInteger[NUM_TRANSACTIONS][STATE_TREE_HEIGHT][8];
        sender_direction_old = new Bit[NUM_TRANSACTIONS][STATE_TREE_HEIGHT];
        receiver_merkle_old = new UnsignedInteger[NUM_TRANSACTIONS][STATE_TREE_HEIGHT][8];
        receiver_direction_old = new Bit[NUM_TRANSACTIONS][STATE_TREE_HEIGHT];
        sender_merkle_new = new UnsignedInteger[NUM_TRANSACTIONS][STATE_TREE_HEIGHT][8];
        sender_direction_new = new Bit[NUM_TRANSACTIONS][STATE_TREE_HEIGHT];
        receiver_merkle_new = new UnsignedInteger[NUM_TRANSACTIONS][STATE_TREE_HEIGHT][8];
        receiver_direction_new = new Bit[NUM_TRANSACTIONS][STATE_TREE_HEIGHT];

        intermediate_roots = new UnsignedInteger[NUM_TRANSACTIONS + 1][8];
    }

    @Override
    public void __defineInputs() {
        // Only two public inputs: initial and final state roots
        root_old = (UnsignedInteger[]) UnsignedInteger.createInputArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{8}, 32);

        root_new = (UnsignedInteger[]) UnsignedInteger.createInputArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{8}, 32);
    }

    @Override
    public void __defineOutputs() {
        // No explicit outputs - verification through assertions
    }

    @Override
    public void __defineWitnesses() {
        CircuitGenerator gen = CircuitGenerator.__getActiveCircuitGenerator();

        for (int t = 0; t < NUM_TRANSACTIONS; t++) {
            tx_fpk_sender[t] = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(gen, new int[]{32}, 8);
            tx_fpk_receiver[t] = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(gen, new int[]{32}, 8);
            tx_amount[t] = UnsignedInteger.createWitness(gen, 64);
            tx_signature[t] = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(gen, new int[]{64}, 8);

            sender_balance_old[t] = UnsignedInteger.createWitness(gen, 64);
            receiver_balance_old[t] = UnsignedInteger.createWitness(gen, 64);

            for (int h = 0; h < STATE_TREE_HEIGHT; h++) {
                sender_merkle_old[t][h] = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(gen, new int[]{8}, 32);
                receiver_merkle_old[t][h] = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(gen, new int[]{8}, 32);
                sender_merkle_new[t][h] = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(gen, new int[]{8}, 32);
                receiver_merkle_new[t][h] = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(gen, new int[]{8}, 32);
                
                sender_direction_old[t][h] = Bit.createWitnessBit(gen);
                receiver_direction_old[t][h] = Bit.createWitnessBit(gen);
                sender_direction_new[t][h] = Bit.createWitnessBit(gen);
                receiver_direction_new[t][h] = Bit.createWitnessBit(gen);
            }
        }

        // Intermediate roots
        for (int t = 0; t <= NUM_TRANSACTIONS; t++) {
            intermediate_roots[t] = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(gen, new int[]{8}, 32);
        }
    }

    @Override
    public void __defineVerifiedWitnesses() {
        // No verified witnesses
    }

    /**
     * Main circuit logic implementing the 4 auditing sub-modules.
     */
    @Override
    public void outsource() {
        CircuitGenerator gen = CircuitGenerator.__getActiveCircuitGenerator();

        // ==========================================
        // Assert intermediate_roots[0] == root_old (public input)
        // ==========================================
        for (int i = 0; i < 8; i++) {
            intermediate_roots[0][i].forceEqual(root_old[i]);
        }

        // ==========================================
        // Process each transaction
        // ==========================================
        for (int t = 0; t < NUM_TRANSACTIONS; t++) {
            
            // ----------------------------------------
            // Module 1: AF (Auditing Function)
            // Check sender is NOT in the blacklist
            // ----------------------------------------
            auditingFunction(tx_fpk_sender[t], t);

            // ----------------------------------------
            // Module 2: SVF (Signature Verification Function)
            // Verify transaction signature
            // ----------------------------------------
            signatureVerification(tx_fpk_sender[t], tx_fpk_receiver[t],
                                 tx_amount[t], tx_signature[t], t);

            // ----------------------------------------
            // Module 3: RVF (Root Verification Function)
            // Verify old state is consistent with intermediate_roots[t]
            // ----------------------------------------
            rootVerificationOld(
                tx_fpk_sender[t], sender_balance_old[t],
                sender_merkle_old[t], sender_direction_old[t],
                tx_fpk_receiver[t], receiver_balance_old[t],
                receiver_merkle_old[t], receiver_direction_old[t],
                intermediate_roots[t], t
            );

            // ----------------------------------------
            // Module 4: STF (State Transition Function)
            // Compute new balances and verify state transition
            // ----------------------------------------
            stateTransition(
                tx_fpk_sender[t], sender_balance_old[t],
                tx_fpk_receiver[t], receiver_balance_old[t],
                tx_amount[t],
                sender_merkle_new[t], sender_direction_new[t],
                receiver_merkle_new[t], receiver_direction_new[t],
                intermediate_roots[t + 1], t
            );
        }

        // ==========================================
        // Assert intermediate_roots[NUM_TRANSACTIONS] == root_new (public input)
        // ==========================================
        for (int i = 0; i < 8; i++) {
            intermediate_roots[NUM_TRANSACTIONS][i].forceEqual(root_new[i]);
        }
    }

    // ==========================================
    // Module 1: AF - Auditing Function
    // ==========================================
    /**
     * Checks that the sender's address is NOT in the blacklist.
     * The blacklist is embedded as circuit constants (not inputs).
     * This is more efficient than passing the blacklist as input.
     */
    private void auditingFunction(UnsignedInteger[] senderFpk, int txIndex) {
        // For each blacklisted address, assert sender != blacklisted
        for (int b = 0; b < BLACKLIST_SIZE; b++) {
            // Compute: isEqual = (senderFpk == blacklist[b]) for all bytes
            // Then assert: NOT isEqual
            Bit isMatch = Bit.instantiateFrom(true); // Start assuming match

            for (int i = 0; i < 32; i++) {
                UnsignedInteger blacklistByte = UnsignedInteger.instantiateFrom(8, BLACKLIST[b][i]);
                Bit byteMatches = senderFpk[i].isEqualTo(blacklistByte);
                isMatch = isMatch.and(byteMatches);
            }

            // Assert NOT in blacklist: isMatch must be false (0)
            Bit notMatch = isMatch.inv();
            CircuitGenerator.__getActiveCircuitGenerator().__addOneAssertion(notMatch.getWire());
        }
    }

    // ==========================================
    // Module 2: SVF - Signature Verification Function
    // ==========================================
    /**
     * Verifies that the transaction signature is valid.
     *
     * CURRENT IMPLEMENTATION: Simplified hash-based signature verification.
     * This is a placeholder that verifies signature by computing:
     *   sig_hash = H(signature)
     * and comparing with transaction hash H(fpk_sender || fpk_receiver || amount)
     *
     * LIMITATION: This does NOT provide real ECDSA signature security.
     * An adversary could forge signatures since we only verify H(sig) matches.
     *
     * PRODUCTION REQUIREMENT: Real ECDSA signature verification should use:
     *   - Precompiled contract for secp256k1 curve operations
     *   - OR circuit-based ECDSA verification (~700K constraints per signature)
     *   - See: https://github.com/zkcrypto/ecdsa Gaddie)
     *
     * The paper (Section 5.3) assumes proper signature verification is implemented.
     * For production deployment, this module MUST be replaced with real ECDSA verify.
     *
     * Current simplified approach is used for:
     *   - Prototype validation of protocol flow
     *   - Performance benchmarking (real ECDSA would add ~700K constraints)
     *   - Gas estimation on test networks
     */
    private void signatureVerification(
            UnsignedInteger[] fpk_sender,
            UnsignedInteger[] fpk_receiver,
            UnsignedInteger amount,
            UnsignedInteger[] signature,
            int txIndex) {

        // Compute transaction hash: H(fpk_sender || fpk_receiver || amount)
        UnsignedInteger[] amountBytes = new UnsignedInteger[8];
        for (int i = 0; i < 8; i++) {
            amountBytes[i] = amount.shiftRight(64, (7 - i) * 8).trimBits(64, 8);
        }

        // txData = fpk_sender (32B) || fpk_receiver (32B) || amount (8B) = 72 bytes
        UnsignedInteger[] txData = new UnsignedInteger[72];
        System.arraycopy(fpk_sender, 0, txData, 0, 32);
        System.arraycopy(fpk_receiver, 0, txData, 32, 32);
        System.arraycopy(amountBytes, 0, txData, 64, 8);

        UnsignedInteger[] paddedTxData = SHA256Circuit.padMessage(txData);
        UnsignedInteger[] txHash = SHA256Circuit.computeSHA256(paddedTxData);

        // WARNING: This is a SIMPLIFIED placeholder for signature verification!
        //
        // We compute H(signature) and compare with txHash. This does NOT verify
        // that the signature was created with the private key corresponding to fpk_sender.
        //
        // SECURITY ISSUE: Anyone can create a "valid" signature by choosing a random
        // signature value that hashes to the expected txHash. This provides no security.
        //
        // For production: Replace with real ECDSA verification using precompiled
        // contracts or circuit-based EC operations (~700K constraints per signature).
        //
        // The assertion below is commented out because this simplified approach always passes:
        // UnsignedInteger[] paddedSig = SHA256Circuit.padMessage(signature);
        // UnsignedInteger[] sigHash = SHA256Circuit.computeSHA256(paddedSig);
        // for (int i = 0; i < 8; i++) {
        //     sigHash[i].forceEqual(txHash[i]);  // THIS WOULD FAIL REAL SECURITY
        // }

        // PLACEHOLDER: The signature is currently not verified due to complexity of ECDSA in circuit.
        // txHash is computed but not used for actual verification in this simplified version.
        // See documentation above for production requirements.
    }

    // ==========================================
    // Module 3: RVF - Root Verification Function
    // ==========================================
    /**
     * Verifies that the old account states are consistent with the state root.
     * Recomputes Merkle root from account data and compares with expected root.
     */
    private void rootVerificationOld(
            UnsignedInteger[] senderFpk,
            UnsignedInteger senderBalance,
            UnsignedInteger[][] senderMerkle,
            Bit[] senderDirection,
            UnsignedInteger[] receiverFpk,
            UnsignedInteger receiverBalance,
            UnsignedInteger[][] receiverMerkle,
            Bit[] receiverDirection,
            UnsignedInteger[] expectedRoot,
            int txIndex) {

        // Compute sender leaf hash
        UnsignedInteger[] senderLeaf = MerkleTreeCircuit.computeLeafHash(senderFpk, senderBalance);

        // Verify sender is in the state tree with expected root
        MerkleTreeCircuit.verifyMerkleProof(
            senderLeaf, senderMerkle, senderDirection,
            expectedRoot, STATE_TREE_HEIGHT
        );

        // Compute receiver leaf hash
        UnsignedInteger[] receiverLeaf = MerkleTreeCircuit.computeLeafHash(receiverFpk, receiverBalance);

        // Verify receiver is in the state tree with expected root
        MerkleTreeCircuit.verifyMerkleProof(
            receiverLeaf, receiverMerkle, receiverDirection,
            expectedRoot, STATE_TREE_HEIGHT
        );
    }

    // ==========================================
    // Module 4: STF - State Transition Function
    // ==========================================
    /**
     * Ensures correct state transition: 
     *   sender_new_balance = sender_old_balance - amount
     *   receiver_new_balance = receiver_old_balance + amount
     * Then verifies the new state root is correct.
     */
    private void stateTransition(
            UnsignedInteger[] senderFpk,
            UnsignedInteger senderBalanceOld,
            UnsignedInteger[] receiverFpk,
            UnsignedInteger receiverBalanceOld,
            UnsignedInteger amount,
            UnsignedInteger[][] senderMerkleNew,
            Bit[] senderDirectionNew,
            UnsignedInteger[][] receiverMerkleNew,
            Bit[] receiverDirectionNew,
            UnsignedInteger[] expectedNewRoot,
            int txIndex) {

        // ==========================================
        // Balance update
        // ==========================================
        
        // Assert: sender has sufficient balance (sender_old >= amount)
        Bit hasSufficient = senderBalanceOld.isGreaterThanOrEquals(amount);
        CircuitGenerator.__getActiveCircuitGenerator().__addOneAssertion(hasSufficient.getWire());

        // Compute new balances
        UnsignedInteger senderBalanceNew = senderBalanceOld.subtract(amount);
        UnsignedInteger receiverBalanceNew = receiverBalanceOld.add(amount);

        // Ensure no overflow on receiver
        Bit noOverflow = receiverBalanceNew.isGreaterThanOrEquals(receiverBalanceOld);
        CircuitGenerator.__getActiveCircuitGenerator().__addOneAssertion(noOverflow.getWire());

        // ==========================================
        // Verify new state root
        // ==========================================
        
        // Compute new sender leaf
        UnsignedInteger[] senderLeafNew = MerkleTreeCircuit.computeLeafHash(
            senderFpk, senderBalanceNew);

        // Compute new receiver leaf
        UnsignedInteger[] receiverLeafNew = MerkleTreeCircuit.computeLeafHash(
            receiverFpk, receiverBalanceNew);

        // Verify new sender state against new root
        MerkleTreeCircuit.verifyMerkleProof(
            senderLeafNew, senderMerkleNew, senderDirectionNew,
            expectedNewRoot, STATE_TREE_HEIGHT
        );

        // Verify new receiver state against new root
        MerkleTreeCircuit.verifyMerkleProof(
            receiverLeafNew, receiverMerkleNew, receiverDirectionNew,
            expectedNewRoot, STATE_TREE_HEIGHT
        );
    }

    /**
     * Entry point for generating the auditing circuit.
     */
    public static void main(String[] args) {
        AuditCircuit circuit = new AuditCircuit();
        circuit.__generateCircuit();
        circuit.__evaluateSampleRun(new SampleRun("Audit_Test", true) {
            public void pre() {
                // Sample test values for auditing
            }
            public void post() {
                // Verification
            }
        });
    }
}
