/**
 * zkCross - Merkle Tree and Merkle Proof Circuit
 * 
 * Implements binary Merkle tree operations used for:
 * - SPV verification in Protocol Θ (transfer)
 * - Transaction inclusion proof in Protocol Φ (exchange)
 * - State root verification in Protocol Ψ (auditing)
 * 
 * Reference: zkCross paper Section 4.1 - State Trees
 */
package zkcross.common;

import backend.structure.CircuitGenerator;
import backend.auxTypes.UnsignedInteger;
import backend.auxTypes.Bit;

public class MerkleTreeCircuit {

    /**
     * Verify a Merkle proof inside the circuit.
     * Proves that a leaf exists in a Merkle tree with a given root.
     * 
     * @param leaf            The 256-bit leaf hash (8 x 32-bit words)
     * @param siblings        Array of sibling hashes at each level (treeHeight x 8 words)
     * @param directionBits   Array of bits indicating left(0)/right(1) at each level
     * @param treeHeight      Height of the Merkle tree
     * @return                The computed Merkle root (8 x 32-bit words)
     */
    public static UnsignedInteger[] computeMerkleRoot(
            UnsignedInteger[] leaf,
            UnsignedInteger[][] siblings,
            Bit[] directionBits,
            int treeHeight) {

        CircuitGenerator gen = CircuitGenerator.__getActiveCircuitGenerator();

        UnsignedInteger[] currentHash = leaf;

        for (int level = 0; level < treeHeight; level++) {
            // Prepare SHA-256 input: concatenate current hash with sibling
            // depending on direction bit
            UnsignedInteger[] hashInput = new UnsignedInteger[64]; // 512 bits = 64 bytes

            for (int j = 0; j < 32; j++) {
                // If directionBit == 0: current is left child -> hash(current || sibling)
                // If directionBit == 1: current is right child -> hash(sibling || current)
                UnsignedInteger currentByte = extractByte(currentHash, j);
                UnsignedInteger siblingByte = extractByte(siblings[level], j);

                // Conditional swap based on direction bit
                // left = directionBit ? sibling : current
                // right = directionBit ? current : sibling
                UnsignedInteger leftByte = conditionalSelect(directionBits[level], siblingByte, currentByte);
                UnsignedInteger rightByte = conditionalSelect(directionBits[level], currentByte, siblingByte);

                hashInput[j] = leftByte;
                hashInput[32 + j] = rightByte;
            }

            // Pad and hash
            UnsignedInteger[] paddedInput = SHA256Circuit.padMessage(hashInput);
            currentHash = SHA256Circuit.computeSHA256(paddedInput);
        }

        return currentHash;
    }

    /**
     * Verify a Merkle proof by comparing computed root with expected root.
     * 
     * @param leaf            The leaf hash
     * @param siblings        Sibling hashes at each level
     * @param directionBits   Direction bits
     * @param expectedRoot    The expected Merkle root
     * @param treeHeight      Height of the tree
     */
    public static void verifyMerkleProof(
            UnsignedInteger[] leaf,
            UnsignedInteger[][] siblings,
            Bit[] directionBits,
            UnsignedInteger[] expectedRoot,
            int treeHeight) {

        UnsignedInteger[] computedRoot = computeMerkleRoot(leaf, siblings, directionBits, treeHeight);

        // Assert computed root equals expected root
        for (int i = 0; i < 8; i++) {
            computedRoot[i].forceEqual(expectedRoot[i]);
        }
    }

    /**
     * Compute the hash of a leaf node = hash(account state).
     * Account state includes: public key (fpk), balance, and other metadata.
     * 
     * @param fpk     Full public key (256 bits = 32 bytes as 8-bit array)
     * @param balance Account balance (64 bits)
     * @return        Leaf hash (8 x 32-bit words)
     */
    public static UnsignedInteger[] computeLeafHash(
            UnsignedInteger[] fpk,
            UnsignedInteger balance) {

        // Concatenate fpk (32 bytes) + balance (8 bytes) = 40 bytes
        UnsignedInteger[] leafData = new UnsignedInteger[40];

        // Copy public key bytes
        for (int i = 0; i < 32; i++) {
            leafData[i] = fpk[i];
        }

        // Convert balance to 8 bytes (big-endian)
        for (int i = 0; i < 8; i++) {
            leafData[32 + i] = balance.shiftRight(64, (7 - i) * 8).trimBits(64, 8);
        }

        // Hash the leaf data
        UnsignedInteger[] padded = SHA256Circuit.padMessage(leafData);
        return SHA256Circuit.computeSHA256(padded);
    }

    /**
     * Update a Merkle tree after a state transition.
     * Computes new root after updating a leaf.
     * Used in Protocol Ψ (STF - State Transition Function).
     */
    public static UnsignedInteger[] updateMerkleRoot(
            UnsignedInteger[] newLeaf,
            UnsignedInteger[][] siblings,
            Bit[] directionBits,
            int treeHeight) {
        return computeMerkleRoot(newLeaf, siblings, directionBits, treeHeight);
    }

    // Helper: extract byte from 32-bit word array
    private static UnsignedInteger extractByte(UnsignedInteger[] words, int byteIndex) {
        int wordIndex = byteIndex / 4;
        int byteOffset = 3 - (byteIndex % 4); // big-endian
        return words[wordIndex].shiftRight(32, byteOffset * 8).trimBits(32, 8);
    }

    // Helper: conditional select - returns a if bit==1, b if bit==0
    private static UnsignedInteger conditionalSelect(Bit bit, UnsignedInteger a, UnsignedInteger b) {
        // result = bit * (a - b) + b
        UnsignedInteger bitAsInt = bit.IsTrue();
        UnsignedInteger diff = a.subtract(b);
        return bitAsInt.multiply(diff).add(b).trimBits(16, 8);
    }
}
