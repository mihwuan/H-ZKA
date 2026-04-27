/**
 * zkCross - Circuit Λ_Θ: Cross-Chain Transfer Protocol (Burn-Mint)
 * 
 * This circuit is used in Protocol Θ for privacy-preserving cross-chain transfers.
 * It proves:
 *   1. The hash h(fpk_R, r, sn) in TxBurn is correctly formed
 *   2. TxBurn is included in a block of Chain I (via Merkle proof)
 *   3. The transfer amount is consistent
 * 
 * Used in two modes:
 *   - Θ.Mint: Receiver claims funds on Chain II
 *   - Θ.Redeem: Sender reclaims funds on Chain I after timeout
 * 
 * Reference: zkCross paper Section 5.1 - Protocol Θ
 */
package zkcross.theta;

import backend.structure.CircuitGenerator;
import backend.eval.SampleRun;
import backend.eval.CircuitEvaluator;
import backend.auxTypes.UnsignedInteger;
import backend.auxTypes.Bit;

import zkcross.common.SHA256Circuit;
import zkcross.common.MerkleTreeCircuit;

public class TransferCircuit extends CircuitGenerator {

    // ==========================================
    // Circuit Configuration
    // ==========================================
    
    /** Height of the Merkle tree (log2 of block size) */
    private static final int TREE_HEIGHT = 4; // block size = 16 transactions

    // ==========================================
    // Public Inputs (known to verifier)
    // ==========================================
    
    /** Receiver's full public key on Chain II (256 bits) */
    private UnsignedInteger[] fpk_R;        // 32 bytes
    
    /** Serial number - unique identifier to prevent double-spending */
    private UnsignedInteger[] sn;           // 32 bytes
    
    /** Transfer amount (denomination) */
    private UnsignedInteger v_S;            // 64 bits
    
    /** Merkle root of the block containing TxBurn on Chain I */
    private UnsignedInteger[] root_Burn;    // 8 x 32-bit words

    // ==========================================
    // Private Inputs / Witnesses (known only to prover)
    // ==========================================
    
    /** Sender's full public key on Chain I (256 bits) */
    private UnsignedInteger[] fpk_S;        // 32 bytes
    
    /** Smart contract address on Chain I */
    private UnsignedInteger[] addr_xi;      // 20 bytes
    
    /** Random number used in hash commitment */
    private UnsignedInteger[] r;            // 32 bytes
    
    /** Merkle proof path hashes: sibling nodes at each tree level.
     *  Per paper Θ.Transmit: sender transmits (r, sn, h_Burn, root_Burn) off-chain.
     *  h_Burn is the FULL Merkle path (array of sibling hashes), NOT just the root.
     *  Combined with directionBits, this forms the SPV proof of TxBurn inclusion. */
    private UnsignedInteger[][] h_Burn;     // TREE_HEIGHT x 8 x 32-bit words
    
    /** Merkle proof direction bits */
    private Bit[] directionBits;            // TREE_HEIGHT bits

    // ==========================================
    // Circuit mode: Mint or Redeem
    // ==========================================
    private boolean isMintMode;

    public TransferCircuit(boolean isMintMode) {
        super("zkCross_Lambda_Theta_" + (isMintMode ? "Mint" : "Redeem"));
        this.isMintMode = isMintMode;
    }

    @Override
    public void __init() {
        fpk_R = new UnsignedInteger[32];
        fpk_S = new UnsignedInteger[32];
        sn = new UnsignedInteger[32];
        addr_xi = new UnsignedInteger[20];
        r = new UnsignedInteger[32];
        root_Burn = new UnsignedInteger[8];
        h_Burn = new UnsignedInteger[TREE_HEIGHT][8];
        directionBits = new Bit[TREE_HEIGHT];
    }

    @Override
    public void __defineInputs() {
        // In Mint mode: fpk_R is public, fpk_S is private
        // In Redeem mode: fpk_S is public, fpk_R is private
        if (isMintMode) {
            fpk_R = (UnsignedInteger[]) UnsignedInteger.createInputArray(
                CircuitGenerator.__getActiveCircuitGenerator(),
                new int[]{32}, 8);
        } else {
            fpk_S = (UnsignedInteger[]) UnsignedInteger.createInputArray(
                CircuitGenerator.__getActiveCircuitGenerator(),
                new int[]{32}, 8);
        }

        sn = (UnsignedInteger[]) UnsignedInteger.createInputArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{32}, 8);

        v_S = UnsignedInteger.createInput(
            CircuitGenerator.__getActiveCircuitGenerator(), 64);

        root_Burn = (UnsignedInteger[]) UnsignedInteger.createInputArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{8}, 32);
    }

    @Override
    public void __defineOutputs() {
        // No explicit outputs - verification is done via assertions
    }

    @Override
    public void __defineWitnesses() {
        // Private witnesses
        if (isMintMode) {
            fpk_S = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
                CircuitGenerator.__getActiveCircuitGenerator(),
                new int[]{32}, 8);
        } else {
            fpk_R = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
                CircuitGenerator.__getActiveCircuitGenerator(),
                new int[]{32}, 8);
        }

        addr_xi = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{20}, 8);

        r = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{32}, 8);

        // Merkle proof witnesses
        for (int i = 0; i < TREE_HEIGHT; i++) {
            h_Burn[i] = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
                CircuitGenerator.__getActiveCircuitGenerator(),
                new int[]{8}, 32);
        }

        directionBits = new Bit[TREE_HEIGHT];
        for (int i = 0; i < TREE_HEIGHT; i++) {
            directionBits[i] = Bit.createWitnessBit(
                CircuitGenerator.__getActiveCircuitGenerator());
        }
    }

    @Override
    public void __defineVerifiedWitnesses() {
        // No verified witnesses needed
    }

    /**
     * Main circuit logic - the outsource() method.
     * 
     * Proves three things:
     * 1. Hash correctness: h(fpk_R, r, sn) is correctly computed
     * 2. Merkle inclusion: TxBurn exists in the block on Chain I
     * 3. Amount consistency: transfer amount matches
     */
    @Override
    public void outsource() {
        CircuitGenerator gen = CircuitGenerator.__getActiveCircuitGenerator();

        // ==========================================
        // Step 1: Compute hash commitment h(fpk_R, r, sn)
        // This binds the receiver's identity to the transaction
        // ==========================================
        
        // Concatenate: fpk_R (32B) || r (32B) || sn (32B) = 96 bytes
        UnsignedInteger[] commitmentInput = new UnsignedInteger[96];
        System.arraycopy(fpk_R, 0, commitmentInput, 0, 32);
        System.arraycopy(r, 0, commitmentInput, 32, 32);
        System.arraycopy(sn, 0, commitmentInput, 64, 32);

        // Hash to get commitment
        UnsignedInteger[] paddedCommitment = SHA256Circuit.padMessage(commitmentInput);
        UnsignedInteger[] hashCommitment = SHA256Circuit.computeSHA256(paddedCommitment);

        // ==========================================
        // Step 2: Compute TxBurn hash for Merkle proof
        // h(TxBurn) = hash(fpk_S, addr_xi, v_S, h(fpk_R, r, sn))
        // ==========================================
        
        // Serialize v_S to 8 bytes (big-endian)
        UnsignedInteger[] vBytes = new UnsignedInteger[8];
        for (int i = 0; i < 8; i++) {
            vBytes[i] = v_S.shiftRight(64, (7 - i) * 8).trimBits(64, 8);
        }

        // Concatenate: fpk_S (32B) || addr_xi (20B) || v_S (8B) || hashCommitment (32B) = 92 bytes
        UnsignedInteger[] txBurnInput = new UnsignedInteger[92];
        System.arraycopy(fpk_S, 0, txBurnInput, 0, 32);
        System.arraycopy(addr_xi, 0, txBurnInput, 32, 20);
        System.arraycopy(vBytes, 0, txBurnInput, 52, 8);

        // Convert hashCommitment (8 x 32-bit) to 32 bytes
        UnsignedInteger[] commitBytes = wordsToBytes(hashCommitment);
        System.arraycopy(commitBytes, 0, txBurnInput, 60, 32);

        UnsignedInteger[] paddedTxBurn = SHA256Circuit.padMessage(txBurnInput);
        UnsignedInteger[] txBurnHash = SHA256Circuit.computeSHA256(paddedTxBurn);

        // ==========================================
        // Step 3: Verify Merkle proof
        // Proves TxBurn is included in the block with root_Burn
        // ==========================================
        
        MerkleTreeCircuit.verifyMerkleProof(
            txBurnHash,     // leaf = h(TxBurn)
            h_Burn,         // sibling hashes
            directionBits,  // path directions
            root_Burn,      // expected root
            TREE_HEIGHT
        );
    }

    /**
     * Convert 8 x 32-bit words to 32 x 8-bit bytes (big-endian)
     */
    private UnsignedInteger[] wordsToBytes(UnsignedInteger[] words) {
        UnsignedInteger[] bytes = new UnsignedInteger[32];
        for (int i = 0; i < 8; i++) {
            for (int j = 0; j < 4; j++) {
                bytes[i * 4 + j] = words[i].shiftRight(32, (3 - j) * 8).trimBits(32, 8);
            }
        }
        return bytes;
    }

    // ==========================================
    // Entry Points
    // ==========================================

    /**
     * Generate Mint circuit (receiver claims on Chain II)
     */
    public static void main(String[] args) {
        // Mint mode
        TransferCircuit mintCircuit = new TransferCircuit(true);
        mintCircuit.__generateCircuit();
        mintCircuit.__evaluateSampleRun(new SampleRun("Mint_Test", true) {
            public void pre() {
                // Sample test values would be assigned here
            }
            public void post() {
                // Verification assertions
            }
        });

        // Redeem mode
        TransferCircuit redeemCircuit = new TransferCircuit(false);
        redeemCircuit.__generateCircuit();
        redeemCircuit.__evaluateSampleRun(new SampleRun("Redeem_Test", true) {
            public void pre() {
                // Sample test values would be assigned here
            }
            public void post() {
                // Verification assertions
            }
        });
    }
}
