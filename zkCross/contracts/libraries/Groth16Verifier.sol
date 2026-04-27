// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Groth16 Verifier Library for zkCross
 * @notice On-chain zk-SNARK (Groth16) proof verification using bn256 precompiled contracts
 * @dev Uses precompiles at addresses 0x06 (bn256Add), 0x07 (bn256ScalarMul), 0x08 (bn256Pairing)
 * 
 * The Groth16 verification equation:
 *   e(A, B) = e(alpha, beta) * e(sum(vk_i * x_i), gamma) * e(C, delta)
 * 
 * Rearranged for single pairing check:
 *   e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) = 1
 * 
 * Reference: zkCross paper Section 6 - Implementation Details
 *            Gas cost: ~440,000 gas for verification
 */
library Groth16Verifier {

    // ==========================================
    // Data Structures
    // ==========================================

    /// @notice Point on G1 (bn256 curve)
    struct G1Point {
        uint256 x;
        uint256 y;
    }

    /// @notice Point on G2 (bn256 twist curve) 
    struct G2Point {
        uint256[2] x; // x coordinate (Fp2 element: x[0] + x[1]*u)
        uint256[2] y; // y coordinate (Fp2 element: y[0] + y[1]*u)
    }

    /// @notice Groth16 proof consisting of three group elements
    struct Proof {
        G1Point a;      // Proof element A (G1)
        G2Point b;      // Proof element B (G2)
        G1Point c;      // Proof element C (G1)
    }

    /// @notice Verification key for a specific circuit
    struct VerifyingKey {
        G1Point alpha;      // alpha * G1
        G2Point beta;       // beta * G2
        G2Point gamma;      // gamma * G2
        G2Point delta;      // delta * G2
        G1Point[] ic;       // IC[i] for public inputs (length = numInputs + 1)
    }

    // ==========================================
    // bn256 Curve Constants
    // ==========================================

    /// @dev Field modulus for bn256
    uint256 internal constant FIELD_MODULUS = 
        21888242871839275222246405745257275088696311157297823662689037894645226208583;

    /// @dev Scalar field order for bn256
    uint256 internal constant SCALAR_MODULUS = 
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // ==========================================
    // Elliptic Curve Operations via Precompiles
    // ==========================================

    /// @notice Negate a G1 point (reflect over x-axis)
    /// @dev -P = (x, FIELD_MODULUS - y)
    function negate(G1Point memory p) internal pure returns (G1Point memory) {
        if (p.x == 0 && p.y == 0) {
            return G1Point(0, 0); // Point at infinity
        }
        return G1Point(p.x, FIELD_MODULUS - (p.y % FIELD_MODULUS));
    }

    /// @notice Add two G1 points using precompile at 0x06
    /// @dev Gas cost: 150 (Istanbul)
    function addition(G1Point memory p1, G1Point memory p2) 
        internal view returns (G1Point memory r) 
    {
        uint256[4] memory input;
        input[0] = p1.x;
        input[1] = p1.y;
        input[2] = p2.x;
        input[3] = p2.y;

        bool success;
        assembly {
            success := staticcall(sub(gas(), 2000), 0x06, input, 0x80, r, 0x40)
        }
        require(success, "bn256Add failed");
    }

    /// @notice Scalar multiplication on G1 using precompile at 0x07
    /// @dev Gas cost: 6,000 (Istanbul)
    function scalarMul(G1Point memory p, uint256 s) 
        internal view returns (G1Point memory r) 
    {
        uint256[3] memory input;
        input[0] = p.x;
        input[1] = p.y;
        input[2] = s;

        bool success;
        assembly {
            success := staticcall(sub(gas(), 2000), 0x07, input, 0x60, r, 0x40)
        }
        require(success, "bn256ScalarMul failed");
    }

    /// @notice Pairing check using precompile at 0x08
    /// @dev Checks: e(p1[0], p2[0]) * e(p1[1], p2[1]) * ... = 1
    /// @dev Gas cost: 45,000 + 34,000 * numPairs (Istanbul)
    function pairing(G1Point[] memory p1, G2Point[] memory p2) 
        internal view returns (bool) 
    {
        require(p1.length == p2.length, "Pairing length mismatch");

        uint256 inputSize = p1.length * 6; // 6 uint256 per pair
        uint256[] memory input = new uint256[](inputSize);

        for (uint256 i = 0; i < p1.length; i++) {
            uint256 j = i * 6;
            input[j + 0] = p1[i].x;
            input[j + 1] = p1[i].y;
            input[j + 2] = p2[i].x[1]; // Note: Fp2 encoding order
            input[j + 3] = p2[i].x[0];
            input[j + 4] = p2[i].y[1];
            input[j + 5] = p2[i].y[0];
        }

        uint256[1] memory result;
        bool success;

        assembly {
            success := staticcall(
                sub(gas(), 2000),
                0x08,
                add(input, 0x20),
                mul(inputSize, 0x20),
                result,
                0x20
            )
        }
        require(success, "bn256Pairing failed");
        return result[0] == 1;
    }

    // ==========================================
    // Groth16 Verification
    // ==========================================

    /**
     * @notice Verify a Groth16 proof against a verification key and public inputs
     * @param vk The verification key for the circuit
     * @param proof The Groth16 proof (A, B, C)
     * @param publicInputs Array of public input values
     * @return True if the proof is valid
     * 
     * @dev Verification equation:
     *   e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) = 1
     * 
     * Where vk_x = IC[0] + sum(IC[i+1] * publicInputs[i])
     */
    function verify(
        VerifyingKey memory vk,
        Proof memory proof,
        uint256[] memory publicInputs
    ) internal view returns (bool) {
        require(publicInputs.length + 1 == vk.ic.length, "Invalid public inputs length");

        // Validate public inputs are in the scalar field
        for (uint256 i = 0; i < publicInputs.length; i++) {
            require(publicInputs[i] < SCALAR_MODULUS, "Public input exceeds field");
        }

        // Compute vk_x = IC[0] + sum(IC[i+1] * publicInputs[i])
        G1Point memory vk_x = vk.ic[0];
        for (uint256 i = 0; i < publicInputs.length; i++) {
            vk_x = addition(vk_x, scalarMul(vk.ic[i + 1], publicInputs[i]));
        }

        // Prepare pairing check: e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) = 1
        G1Point[] memory g1Points = new G1Point[](4);
        G2Point[] memory g2Points = new G2Point[](4);

        g1Points[0] = negate(proof.a);  // -A
        g2Points[0] = proof.b;          // B

        g1Points[1] = vk.alpha;         // alpha
        g2Points[1] = vk.beta;          // beta

        g1Points[2] = vk_x;             // vk_x (computed)
        g2Points[2] = vk.gamma;         // gamma

        g1Points[3] = proof.c;          // C
        g2Points[3] = vk.delta;         // delta

        return pairing(g1Points, g2Points);
    }
}
