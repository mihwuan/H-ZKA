/**
 * zkCross - Circuit Λ^on_Φ: Cross-Chain Exchange Unlock (On-chain)
 * 
 * This circuit is used in Protocol Φ for the on-chain Unlock step.
 * Similar to Λ_Θ (Hash + Merkle Proof), with modifications for HTLC unlock.
 * 
 * It proves:
 *   1. TxLock exists in a block (via Merkle proof)
 *   2. The preimage correctly corresponds to the hash lock
 *   3. The unlock operation is legitimate
 * 
 * Two modes:
 *   - S_II unlocks on Chain II (using sn_II, pre_II)
 *   - R_I unlocks on Chain I (using sn_I, pre_I)
 * 
 * Reference: zkCross paper Section 5.2 - Protocol Φ, Step Φ.Unlock
 */
package zkcross.phi;

import backend.structure.CircuitGenerator;
import backend.eval.SampleRun;
import backend.eval.CircuitEvaluator;
import backend.auxTypes.UnsignedInteger;
import backend.auxTypes.Bit;

import zkcross.common.SHA256Circuit;
import zkcross.common.MerkleTreeCircuit;

public class ExchangeUnlockCircuit extends CircuitGenerator {

    // ==========================================
    // Circuit Configuration
    // ==========================================
    
    private static final int TREE_HEIGHT = 4; // block size = 16

    // ==========================================
    // Public Inputs
    // ==========================================
    
    /** Serial number for this chain */
    private UnsignedInteger[] sn;           // 32 bytes
    
    /** Exchange amount */
    private UnsignedInteger v;              // 64 bits
    
    /** Merkle root of block containing TxLock */
    private UnsignedInteger[] root_Lock;    // 8 x 32-bit words

    // ==========================================
    // Private Inputs / Witnesses
    // ==========================================
    
    /** Counterparty's full public key on this chain */
    private UnsignedInteger[] fpk;          // 32 bytes
    
    /** Smart contract address on this chain */
    private UnsignedInteger[] addr_xi;      // 20 bytes
    
    /** Preimage for hash lock */
    private UnsignedInteger[] pre;          // 32 bytes
    
    /** Merkle proof path hashes */
    private UnsignedInteger[][] h_Lock;     // TREE_HEIGHT x 8 x 32-bit
    
    /** Merkle proof direction bits */
    private Bit[] directionBits;
    
    /** Hash of TxLock transaction */
    private UnsignedInteger[] h_TxLock;     // 8 x 32-bit
    
    /** Hash lock value: h(pre, sn) */
    private UnsignedInteger[] h_pre_sn;     // 8 x 32-bit

    /** Chain identifier (true = Chain II for S, false = Chain I for R) */
    private boolean isChainII;

    public ExchangeUnlockCircuit(boolean isChainII) {
        super("zkCross_Lambda_Phi_OnChain_" + (isChainII ? "ChainII" : "ChainI"));
        this.isChainII = isChainII;
    }

    @Override
    public void __init() {
        sn = new UnsignedInteger[32];
        fpk = new UnsignedInteger[32];
        addr_xi = new UnsignedInteger[20];
        pre = new UnsignedInteger[32];
        root_Lock = new UnsignedInteger[8];
        h_Lock = new UnsignedInteger[TREE_HEIGHT][8];
        directionBits = new Bit[TREE_HEIGHT];
        h_TxLock = new UnsignedInteger[8];
        h_pre_sn = new UnsignedInteger[8];
    }

    @Override
    public void __defineInputs() {
        sn = (UnsignedInteger[]) UnsignedInteger.createInputArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{32}, 8);

        v = UnsignedInteger.createInput(
            CircuitGenerator.__getActiveCircuitGenerator(), 64);

        root_Lock = (UnsignedInteger[]) UnsignedInteger.createInputArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{8}, 32);
    }

    @Override
    public void __defineOutputs() {
        // No explicit outputs
    }

    @Override
    public void __defineWitnesses() {
        fpk = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{32}, 8);

        addr_xi = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{20}, 8);

        pre = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{32}, 8);

        for (int i = 0; i < TREE_HEIGHT; i++) {
            h_Lock[i] = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
                CircuitGenerator.__getActiveCircuitGenerator(),
                new int[]{8}, 32);
        }

        directionBits = new Bit[TREE_HEIGHT];
        for (int i = 0; i < TREE_HEIGHT; i++) {
            directionBits[i] = Bit.createWitnessBit(
                CircuitGenerator.__getActiveCircuitGenerator());
        }

        h_TxLock = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{8}, 32);

        h_pre_sn = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{8}, 32);
    }

    @Override
    public void __defineVerifiedWitnesses() {
        // No verified witnesses
    }

    /**
     * Main circuit logic.
     * 
     * Proves:
     * 1. Hash lock correctness: h(pre, sn) is computed correctly
     * 2. Transaction hash: h(TxLock) = hash(fpk, addr_xi, v, h(pre, sn))
     * 3. Merkle inclusion: TxLock exists in the block with root_Lock
     */
    @Override
    public void outsource() {
        CircuitGenerator gen = CircuitGenerator.__getActiveCircuitGenerator();

        // ==========================================
        // Step 1: Verify hash lock h(pre, sn)
        // ==========================================
        
        // Concatenate pre (32B) || sn (32B) = 64 bytes
        UnsignedInteger[] hashLockInput = new UnsignedInteger[64];
        System.arraycopy(pre, 0, hashLockInput, 0, 32);
        System.arraycopy(sn, 0, hashLockInput, 32, 32);

        UnsignedInteger[] paddedHashLock = SHA256Circuit.padMessage(hashLockInput);
        UnsignedInteger[] computed_h_pre_sn = SHA256Circuit.computeSHA256(paddedHashLock);

        // Assert matches witness h_pre_sn
        for (int i = 0; i < 8; i++) {
            computed_h_pre_sn[i].forceEqual(h_pre_sn[i]);
        }

        // ==========================================
        // Step 2: Compute TxLock hash
        // h(TxLock) = hash(fpk, addr_xi, v, h(pre, sn))
        // ==========================================
        
        // Serialize v to 8 bytes
        UnsignedInteger[] vBytes = new UnsignedInteger[8];
        for (int i = 0; i < 8; i++) {
            vBytes[i] = v.shiftRight(64, (7 - i) * 8).trimBits(64, 8);
        }

        // Convert h_pre_sn to bytes
        UnsignedInteger[] hashLockBytes = wordsToBytes(h_pre_sn);

        // Concatenate: fpk (32B) || addr_xi (20B) || v (8B) || h_pre_sn (32B) = 92 bytes
        UnsignedInteger[] txLockInput = new UnsignedInteger[92];
        System.arraycopy(fpk, 0, txLockInput, 0, 32);
        System.arraycopy(addr_xi, 0, txLockInput, 32, 20);
        System.arraycopy(vBytes, 0, txLockInput, 52, 8);
        System.arraycopy(hashLockBytes, 0, txLockInput, 60, 32);

        UnsignedInteger[] paddedTxLock = SHA256Circuit.padMessage(txLockInput);
        UnsignedInteger[] computed_h_TxLock = SHA256Circuit.computeSHA256(paddedTxLock);

        // Assert matches witness h_TxLock
        for (int i = 0; i < 8; i++) {
            computed_h_TxLock[i].forceEqual(h_TxLock[i]);
        }

        // ==========================================
        // Step 3: Verify Merkle proof
        // TxLock exists in block with root_Lock
        // ==========================================
        
        MerkleTreeCircuit.verifyMerkleProof(
            computed_h_TxLock,  // leaf = h(TxLock)
            h_Lock,             // sibling hashes
            directionBits,      // path directions
            root_Lock,          // expected root
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

    /**
     * Entry point for generating exchange unlock circuits.
     */
    public static void main(String[] args) {
        // Chain II unlock (S_II unlocks R's locked funds)
        ExchangeUnlockCircuit chainII = new ExchangeUnlockCircuit(true);
        chainII.__generateCircuit();
        chainII.__evaluateSampleRun(new SampleRun("ChainII_Unlock_Test", true) {
            public void pre() {}
            public void post() {}
        });

        // Chain I unlock (R_I unlocks S's locked funds)
        ExchangeUnlockCircuit chainI = new ExchangeUnlockCircuit(false);
        chainI.__generateCircuit();
        chainI.__evaluateSampleRun(new SampleRun("ChainI_Unlock_Test", true) {
            public void pre() {}
            public void post() {}
        });
    }
}
