/**
 * zkCross - Groth16 Verifier Precompiled Contract for go-ethereum
 *
 * This file adds a native Groth16 proof verification precompiled contract
 * to go-ethereum at address 0x20. This is the modification described in
 * the zkCross paper Section 6 (Implementation Details):
 *
 *   "We modified go-ethereum and Solidity source code to add a function
 *    for ZKP proof verification in smart contracts. Gas: 440,000."
 *
 * The precompile verifies Groth16 proofs on the bn256 (alt_bn128) curve
 * using the existing bn256 pairing machinery in go-ethereum.
 *
 * Input format (ABI-encoded):
 *   - Proof A (G1): 64 bytes (x: 32B, y: 32B)
 *   - Proof B (G2): 128 bytes (x0: 32B, x1: 32B, y0: 32B, y1: 32B)
 *   - Proof C (G1): 64 bytes
 *   - VK Alpha (G1): 64 bytes
 *   - VK Beta (G2): 128 bytes
 *   - VK Gamma (G2): 128 bytes
 *   - VK Delta (G2): 128 bytes
 *   - numPublicInputs: 32 bytes (uint256)
 *   - IC[0..numPublicInputs] (G1): 64 * (numPublicInputs + 1) bytes
 *   - publicInputs[0..numPublicInputs-1]: 32 * numPublicInputs bytes
 *
 * Output: 32 bytes (1 = valid, 0 = invalid)
 *
 * Gas cost: 440,000 (as specified in the paper)
 */

package vm

import (
	"errors"
	"math/big"

	"github.com/ethereum/go-ethereum/crypto/bn256"
)

// zkCross Groth16 gas cost (paper Section 6)
const Groth16VerifyGas = 440000

// groth16Verify implements the Groth16 proof verification precompiled contract
type groth16Verify struct{}

func (c *groth16Verify) RequiredGas(input []byte) uint64 {
	return Groth16VerifyGas
}

func (c *groth16Verify) Name() string {
	return "GROTH16_VERIFY"
}

// errBadGroth16Input is returned when the Groth16 input is malformed
var errBadGroth16Input = errors.New("bad Groth16 verification input")

/**
 * Run executes the Groth16 verification.
 *
 * Verification equation:
 *   e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) == 1
 *
 * Where vk_x = IC[0] + sum(IC[i+1] * publicInputs[i])
 */
func (c *groth16Verify) Run(input []byte) ([]byte, error) {
	// Minimum input: proof(256) + vk(448) + numInputs(32) + IC[0](64) = 800 bytes
	if len(input) < 800 {
		return nil, errBadGroth16Input
	}

	offset := 0

	// Parse Proof A (G1): 64 bytes
	proofA, err := newCurvePoint(input[offset : offset+64])
	if err != nil {
		return nil, err
	}
	offset += 64

	// Parse Proof B (G2): 128 bytes
	proofB, err := newTwistPoint(input[offset : offset+128])
	if err != nil {
		return nil, err
	}
	offset += 128

	// Parse Proof C (G1): 64 bytes
	proofC, err := newCurvePoint(input[offset : offset+64])
	if err != nil {
		return nil, err
	}
	offset += 64

	// Parse VK Alpha (G1): 64 bytes
	vkAlpha, err := newCurvePoint(input[offset : offset+64])
	if err != nil {
		return nil, err
	}
	offset += 64

	// Parse VK Beta (G2): 128 bytes
	vkBeta, err := newTwistPoint(input[offset : offset+128])
	if err != nil {
		return nil, err
	}
	offset += 128

	// Parse VK Gamma (G2): 128 bytes
	vkGamma, err := newTwistPoint(input[offset : offset+128])
	if err != nil {
		return nil, err
	}
	offset += 128

	// Parse VK Delta (G2): 128 bytes
	vkDelta, err := newTwistPoint(input[offset : offset+128])
	if err != nil {
		return nil, err
	}
	offset += 128

	// Parse number of public inputs: 32 bytes
	if offset+32 > len(input) {
		return nil, errBadGroth16Input
	}
	numInputs := new(big.Int).SetBytes(input[offset : offset+32])
	offset += 32

	numInputsInt := int(numInputs.Int64())
	if numInputsInt < 0 || numInputsInt > 100 {
		return nil, errBadGroth16Input
	}

	// Validate remaining input length
	expectedRemaining := (numInputsInt+1)*64 + numInputsInt*32
	if offset+expectedRemaining != len(input) {
		return nil, errBadGroth16Input
	}

	// Parse IC points (numInputs + 1 G1 points)
	ic := make([]*bn256.G1, numInputsInt+1)
	for i := 0; i <= numInputsInt; i++ {
		ic[i], err = newCurvePoint(input[offset : offset+64])
		if err != nil {
			return nil, err
		}
		offset += 64
	}

	// Parse public inputs (numInputs uint256 values)
	publicInputs := make([]*big.Int, numInputsInt)
	for i := 0; i < numInputsInt; i++ {
		publicInputs[i] = new(big.Int).SetBytes(input[offset : offset+32])
		offset += 32
	}

	// ==========================================
	// Compute vk_x = IC[0] + sum(IC[i+1] * publicInputs[i])
	// ==========================================
	vkX := new(bn256.G1).Set(ic[0])
	for i := 0; i < numInputsInt; i++ {
		// Scalar multiply IC[i+1] by publicInputs[i]
		term := new(bn256.G1).ScalarMult(ic[i+1], publicInputs[i])
		// Add to accumulator
		vkX = new(bn256.G1).Add(vkX, term)
	}

	// ==========================================
	// Pairing check: e(-A, B) * e(alpha, beta) * e(vk_x, gamma) * e(C, delta) == 1
	// ==========================================

	// Negate A: -A
	negA := new(bn256.G1).Neg(proofA)

	// Prepare pairing inputs
	g1Points := []*bn256.G1{negA, vkAlpha, vkX, proofC}
	g2Points := []*bn256.G2{proofB, vkBeta, vkGamma, vkDelta}

	// Execute pairing check
	if bn256.PairingCheck(g1Points, g2Points) {
		return true32Byte, nil
	}
	return false32Byte, nil
}
