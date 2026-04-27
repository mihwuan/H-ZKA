/**
 * zkCross - SHA-256 Hash Circuit
 * 
 * Implements SHA-256 as a circuit component used by all three protocols (Θ, Φ, Ψ).
 * Based on the xjsnark framework pattern for building zk-SNARK circuits.
 * 
 * Reference: zkCross paper Section 4 - Cryptographic Primitives
 */
package zkcross.common;

import backend.structure.CircuitGenerator;
import backend.auxTypes.UnsignedInteger;
import backend.auxTypes.Bit;

public class SHA256Circuit {

    // SHA-256 constants: first 32 bits of fractional parts of cube roots of first 64 primes
    private static final long[] K = {
        0x428a2f98L, 0x71374491L, 0xb5c0fbcfL, 0xe9b5dba5L,
        0x3956c25bL, 0x59f111f1L, 0x923f82a4L, 0xab1c5ed5L,
        0xd807aa98L, 0x12835b01L, 0x243185beL, 0x550c7dc3L,
        0x72be5d74L, 0x80deb1feL, 0x9bdc06a7L, 0xc19bf174L,
        0xe49b69c1L, 0xefbe4786L, 0x0fc19dc6L, 0x240ca1ccL,
        0x2de92c6fL, 0x4a7484aaL, 0x5cb0a9dcL, 0x76f988daL,
        0x983e5152L, 0xa831c66dL, 0xb00327c8L, 0xbf597fc7L,
        0xc6e00bf3L, 0xd5a79147L, 0x06ca6351L, 0x14292967L,
        0x27b70a85L, 0x2e1b2138L, 0x4d2c6dfcL, 0x53380d13L,
        0x650a7354L, 0x766a0abbL, 0x81c2c92eL, 0x92722c85L,
        0xa2bfe8a1L, 0xa81a664bL, 0xc24b8b70L, 0xc76c51a3L,
        0xd192e819L, 0xd6990624L, 0xf40e3585L, 0x106aa070L,
        0x19a4c116L, 0x1e376c08L, 0x2748774cL, 0x34b0bcb5L,
        0x391c0cb3L, 0x4ed8aa4aL, 0x5b9cca4fL, 0x682e6ff3L,
        0x748f82eeL, 0x78a5636fL, 0x84c87814L, 0x8cc70208L,
        0x90befffaL, 0xa4506cebL, 0xbef9a3f7L, 0xc67178f2L
    };

    // Initial hash values: first 32 bits of fractional parts of square roots of first 8 primes
    private static final long[] H_INIT = {
        0x6a09e667L, 0xbb67ae85L, 0x3c6ef372L, 0xa54ff53aL,
        0x510e527fL, 0x9b05688cL, 0x1f83d9abL, 0x5be0cd19L
    };

    /**
     * Compute SHA-256 hash inside the circuit.
     * Input: array of 8-bit UnsignedIntegers (pre-padded to 64 bytes for single block)
     * Output: array of 8 x 32-bit UnsignedIntegers (256-bit hash)
     */
    public static UnsignedInteger[] computeSHA256(UnsignedInteger[] inputBytes) {
        CircuitGenerator gen = CircuitGenerator.__getActiveCircuitGenerator();

        // Convert input bytes to 32-bit words (16 words for one block)
        int numBlocks = (inputBytes.length + 8 + 64) / 64; // with padding
        UnsignedInteger[] messageWords = new UnsignedInteger[64];

        // First 16 words from input (4 bytes each)
        for (int i = 0; i < 16; i++) {
            if (i * 4 < inputBytes.length) {
                messageWords[i] = packBytes(inputBytes, i * 4, gen);
            } else {
                messageWords[i] = UnsignedInteger.instantiateFrom(32, 0);
            }
        }

        // Message schedule: extend to 64 words
        for (int i = 16; i < 64; i++) {
            UnsignedInteger s0 = xorThree(
                rightRotate(messageWords[i - 15], 7, 32),
                rightRotate(messageWords[i - 15], 18, 32),
                rightShift(messageWords[i - 15], 3, 32),
                gen
            );
            UnsignedInteger s1 = xorThree(
                rightRotate(messageWords[i - 2], 17, 32),
                rightRotate(messageWords[i - 2], 19, 32),
                rightShift(messageWords[i - 2], 10, 32),
                gen
            );
            messageWords[i] = addMod32(
                addMod32(messageWords[i - 16], s0, gen),
                addMod32(messageWords[i - 7], s1, gen),
                gen
            );
        }

        // Initialize working variables
        UnsignedInteger a = UnsignedInteger.instantiateFrom(32, H_INIT[0]);
        UnsignedInteger b = UnsignedInteger.instantiateFrom(32, H_INIT[1]);
        UnsignedInteger c = UnsignedInteger.instantiateFrom(32, H_INIT[2]);
        UnsignedInteger d = UnsignedInteger.instantiateFrom(32, H_INIT[3]);
        UnsignedInteger e = UnsignedInteger.instantiateFrom(32, H_INIT[4]);
        UnsignedInteger f = UnsignedInteger.instantiateFrom(32, H_INIT[5]);
        UnsignedInteger g = UnsignedInteger.instantiateFrom(32, H_INIT[6]);
        UnsignedInteger h = UnsignedInteger.instantiateFrom(32, H_INIT[7]);

        // Compression rounds
        for (int i = 0; i < 64; i++) {
            UnsignedInteger S1 = xorThree(
                rightRotate(e, 6, 32),
                rightRotate(e, 11, 32),
                rightRotate(e, 25, 32),
                gen
            );
            UnsignedInteger ch = choice(e, f, g, gen);
            UnsignedInteger temp1 = addMod32(
                addMod32(addMod32(h, S1, gen), ch, gen),
                addMod32(
                    UnsignedInteger.instantiateFrom(32, K[i]),
                    messageWords[i], gen
                ),
                gen
            );

            UnsignedInteger S0 = xorThree(
                rightRotate(a, 2, 32),
                rightRotate(a, 13, 32),
                rightRotate(a, 22, 32),
                gen
            );
            UnsignedInteger maj = majority(a, b, c, gen);
            UnsignedInteger temp2 = addMod32(S0, maj, gen);

            h = g;
            g = f;
            f = e;
            e = addMod32(d, temp1, gen);
            d = c;
            c = b;
            b = a;
            a = addMod32(temp1, temp2, gen);
        }

        // Final hash value
        UnsignedInteger[] result = new UnsignedInteger[8];
        result[0] = addMod32(a, UnsignedInteger.instantiateFrom(32, H_INIT[0]), gen);
        result[1] = addMod32(b, UnsignedInteger.instantiateFrom(32, H_INIT[1]), gen);
        result[2] = addMod32(c, UnsignedInteger.instantiateFrom(32, H_INIT[2]), gen);
        result[3] = addMod32(d, UnsignedInteger.instantiateFrom(32, H_INIT[3]), gen);
        result[4] = addMod32(e, UnsignedInteger.instantiateFrom(32, H_INIT[4]), gen);
        result[5] = addMod32(f, UnsignedInteger.instantiateFrom(32, H_INIT[5]), gen);
        result[6] = addMod32(g, UnsignedInteger.instantiateFrom(32, H_INIT[6]), gen);
        result[7] = addMod32(h, UnsignedInteger.instantiateFrom(32, H_INIT[7]), gen);

        return result;
    }

    // Helper: pack 4 bytes into a 32-bit word (big-endian)
    private static UnsignedInteger packBytes(UnsignedInteger[] bytes, int offset, CircuitGenerator gen) {
        UnsignedInteger result = UnsignedInteger.instantiateFrom(32, 0);
        for (int i = 0; i < 4 && (offset + i) < bytes.length; i++) {
            UnsignedInteger shifted = bytes[offset + i].shiftLeft(32, (3 - i) * 8);
            result = result.xorBitwise(shifted, 32);
        }
        return result;
    }

    // Helper: Right rotate for 32-bit values
    private static UnsignedInteger rightRotate(UnsignedInteger val, int shift, int bitwidth) {
        UnsignedInteger right = val.shiftRight(bitwidth, shift);
        UnsignedInteger left = val.shiftLeft(bitwidth, bitwidth - shift);
        return right.orBitwise(left, bitwidth);
    }

    // Helper: Right shift for 32-bit values
    private static UnsignedInteger rightShift(UnsignedInteger val, int shift, int bitwidth) {
        return val.shiftRight(bitwidth, shift);
    }

    // Helper: XOR three values
    private static UnsignedInteger xorThree(UnsignedInteger a, UnsignedInteger b, UnsignedInteger c, CircuitGenerator gen) {
        return a.xorBitwise(b, 32).xorBitwise(c, 32);
    }

    // Helper: Addition modulo 2^32
    private static UnsignedInteger addMod32(UnsignedInteger a, UnsignedInteger b, CircuitGenerator gen) {
        return a.add(b).trimBits(33, 32);
    }

    // Helper: Ch(e, f, g) = (e AND f) XOR (NOT e AND g)
    private static UnsignedInteger choice(UnsignedInteger e, UnsignedInteger f, UnsignedInteger g, CircuitGenerator gen) {
        UnsignedInteger ef = e.andBitwise(f, 32);
        UnsignedInteger notE = e.invBits(32);
        UnsignedInteger notEg = notE.andBitwise(g, 32);
        return ef.xorBitwise(notEg, 32);
    }

    // Helper: Maj(a, b, c) = (a AND b) XOR (a AND c) XOR (b AND c)
    private static UnsignedInteger majority(UnsignedInteger a, UnsignedInteger b, UnsignedInteger c, CircuitGenerator gen) {
        UnsignedInteger ab = a.andBitwise(b, 32);
        UnsignedInteger ac = a.andBitwise(c, 32);
        UnsignedInteger bc = b.andBitwise(c, 32);
        return ab.xorBitwise(ac, 32).xorBitwise(bc, 32);
    }

    /**
     * Pad a message for SHA-256 (in-circuit).
     * Adds 1-bit, zeros, and 64-bit length to make total length multiple of 512 bits.
     */
    public static UnsignedInteger[] padMessage(UnsignedInteger[] message) {
        int originalLength = message.length;
        int paddedLength = ((originalLength + 8 + 64) / 64) * 64;
        UnsignedInteger[] padded = new UnsignedInteger[paddedLength];

        // Copy original message
        for (int i = 0; i < originalLength; i++) {
            padded[i] = message[i];
        }

        // Append 0x80
        padded[originalLength] = UnsignedInteger.instantiateFrom(8, 0x80);

        // Zero padding
        for (int i = originalLength + 1; i < paddedLength - 8; i++) {
            padded[i] = UnsignedInteger.instantiateFrom(8, 0);
        }

        // Append original length in bits (big-endian, 64-bit)
        long bitLength = (long) originalLength * 8;
        for (int i = 0; i < 8; i++) {
            padded[paddedLength - 8 + i] = UnsignedInteger.instantiateFrom(8,
                (int) ((bitLength >> (56 - i * 8)) & 0xFF));
        }

        return padded;
    }
}
