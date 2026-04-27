/**
 * zkCross - Circuit Λ^off_Φ: Cross-Chain Exchange Prepare (Off-chain)
 * 
 * This circuit is used in Protocol Φ for the off-chain Prepare step.
 * It proves:
 *   1. The relationship between sn_I and sn_II (linked via XOR with Z_256)
 *   2. Hash locks h(pre_I, sn_I) and h(pre_II, sn_II) are correctly computed
 *   3. R can derive sn_I from sn_II via reverse XOR
 * 
 * Key innovation: Uses independent preimages instead of shared preimage (standard HTLC)
 * to prevent cross-chain linkability.
 * 
 * Reference: zkCross paper Section 5.2 - Protocol Φ, Step Φ.Prepare
 */
package zkcross.phi;

import backend.structure.CircuitGenerator;
import backend.eval.SampleRun;
import backend.eval.CircuitEvaluator;
import backend.auxTypes.UnsignedInteger;
import backend.auxTypes.Bit;

import zkcross.common.SHA256Circuit;

public class ExchangePrepareCircuit extends CircuitGenerator {

    // ==========================================
    // Public Inputs
    // ==========================================
    
    /** Preimage for Chain I hash lock */
    private UnsignedInteger[] pre_I;        // 32 bytes
    
    /** Preimage for Chain II hash lock */
    private UnsignedInteger[] pre_II;       // 32 bytes
    
    /** 256-bit integer linking sn_I and sn_II via XOR */
    private UnsignedInteger[] Z_256;        // 32 bytes
    
    /** Hash lock for Chain I: h(pre_I, sn_I) */
    private UnsignedInteger[] h_pre_sn_I;   // 8 x 32-bit (SHA-256 output)
    
    /** Hash lock for Chain II: h(pre_II, sn_II) */
    private UnsignedInteger[] h_pre_sn_II;  // 8 x 32-bit (SHA-256 output)

    // ==========================================
    // Private Inputs / Witnesses
    // ==========================================
    
    /** Serial number for Chain I */
    private UnsignedInteger[] sn_I;         // 32 bytes
    
    /** Serial number for Chain II */
    private UnsignedInteger[] sn_II;        // 32 bytes

    public ExchangePrepareCircuit() {
        super("zkCross_Lambda_Phi_OffChain");
    }

    @Override
    public void __init() {
        pre_I = new UnsignedInteger[32];
        pre_II = new UnsignedInteger[32];
        Z_256 = new UnsignedInteger[32];
        h_pre_sn_I = new UnsignedInteger[8];
        h_pre_sn_II = new UnsignedInteger[8];
        sn_I = new UnsignedInteger[32];
        sn_II = new UnsignedInteger[32];
    }

    @Override
    public void __defineInputs() {
        pre_I = (UnsignedInteger[]) UnsignedInteger.createInputArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{32}, 8);

        pre_II = (UnsignedInteger[]) UnsignedInteger.createInputArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{32}, 8);

        Z_256 = (UnsignedInteger[]) UnsignedInteger.createInputArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{32}, 8);

        h_pre_sn_I = (UnsignedInteger[]) UnsignedInteger.createInputArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{8}, 32);

        h_pre_sn_II = (UnsignedInteger[]) UnsignedInteger.createInputArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{8}, 32);
    }

    @Override
    public void __defineOutputs() {
        // No explicit outputs
    }

    @Override
    public void __defineWitnesses() {
        sn_I = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{32}, 8);

        sn_II = (UnsignedInteger[]) UnsignedInteger.createWitnessArray(
            CircuitGenerator.__getActiveCircuitGenerator(),
            new int[]{32}, 8);
    }

    @Override
    public void __defineVerifiedWitnesses() {
        // No verified witnesses
    }

    /**
     * Main circuit logic.
     * 
     * Proves:
     * 1. sn_II = sn_I XOR Z_256 (linking serial numbers)
     * 2. h(pre_I, sn_I) matches public h_pre_sn_I
     * 3. h(pre_II, sn_II) matches public h_pre_sn_II
     */
    @Override
    public void outsource() {
        CircuitGenerator gen = CircuitGenerator.__getActiveCircuitGenerator();

        // ==========================================
        // Step 1: Verify XOR relationship
        // sn_II = sn_I XOR Z_256
        // ==========================================
        for (int i = 0; i < 32; i++) {
            UnsignedInteger computed_sn_II_byte = sn_I[i].xorBitwise(Z_256[i], 8);
            computed_sn_II_byte.forceEqual(sn_II[i]);
        }

        // ==========================================
        // Step 2: Verify hash lock for Chain I
        // h(pre_I, sn_I) = h_pre_sn_I
        // ==========================================
        
        // Concatenate pre_I (32B) || sn_I (32B) = 64 bytes
        UnsignedInteger[] hashInput_I = new UnsignedInteger[64];
        System.arraycopy(pre_I, 0, hashInput_I, 0, 32);
        System.arraycopy(sn_I, 0, hashInput_I, 32, 32);

        UnsignedInteger[] paddedInput_I = SHA256Circuit.padMessage(hashInput_I);
        UnsignedInteger[] computed_h_I = SHA256Circuit.computeSHA256(paddedInput_I);

        // Assert hash matches public input
        for (int i = 0; i < 8; i++) {
            computed_h_I[i].forceEqual(h_pre_sn_I[i]);
        }

        // ==========================================
        // Step 3: Verify hash lock for Chain II
        // h(pre_II, sn_II) = h_pre_sn_II
        // ==========================================
        
        // Concatenate pre_II (32B) || sn_II (32B) = 64 bytes
        UnsignedInteger[] hashInput_II = new UnsignedInteger[64];
        System.arraycopy(pre_II, 0, hashInput_II, 0, 32);
        System.arraycopy(sn_II, 0, hashInput_II, 32, 32);

        UnsignedInteger[] paddedInput_II = SHA256Circuit.padMessage(hashInput_II);
        UnsignedInteger[] computed_h_II = SHA256Circuit.computeSHA256(paddedInput_II);

        // Assert hash matches public input
        for (int i = 0; i < 8; i++) {
            computed_h_II[i].forceEqual(h_pre_sn_II[i]);
        }
    }

    /**
     * Entry point for generating the off-chain exchange prepare circuit.
     */
    public static void main(String[] args) {
        ExchangePrepareCircuit circuit = new ExchangePrepareCircuit();
        circuit.__generateCircuit();
        circuit.__evaluateSampleRun(new SampleRun("Prepare_Test", true) {
            public void pre() {
                // Test values would be assigned here
            }
            public void post() {
                // Verification
            }
        });
    }
}
