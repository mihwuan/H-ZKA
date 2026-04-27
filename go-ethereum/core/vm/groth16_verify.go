// Copyright 2024 The go-ethereum Authors
// This file is part of the go-ethereum library.
//
// zkCross modification: Groth16 zk-SNARK proof verification precompiled contract
// Reference: "zkCross: A Novel Architecture for Cross-Chain Privacy-Preserving Auditing"
//            USENIX Security 2024, Section 6 - Implementation Details
//
// Gas cost: 440,000 (equivalent to Groth16 verification as stated in the paper)

package vm

import (
	"errors"
	"math/big"

	"github.com/ethereum/go-ethereum/crypto/bn256"
	"github.com/ethereum/go-ethereum/params"
)

var errBadGroth16Input = errors.New("bad Groth16 verification input")

// groth16Verify implements native Groth16 proof verification as a precompiled contract.
// This is the modification described in the zkCross paper:
//
//	"We modified go-ethereum and Solidity source code to add a function
//	 for ZKP proof verification in smart contracts."
//
// The precompile receives a Groth16 proof, verification key, and public inputs,
// then verifies the proof using the bn256 pairing operation.
//
// Input encoding (tightly packed):
//
//	proof_a:       64 bytes  (G1 point: x 32B, y 32B)
//	proof_b:      128 bytes  (G2 point: x0 32B, x1 32B, y0 32B, y1 32B)
//	proof_c:       64 bytes  (G1 point)
//	vk_alpha:      64 bytes  (G1 point)
//	vk_beta:      128 bytes  (G2 point)
//	vk_gamma:     128 bytes  (G2 point)
//	vk_delta:     128 bytes  (G2 point)
//	num_inputs:    32 bytes  (uint256, max 100)
//	ic[0..n]:     64*(n+1) bytes  (G1 points, n = num_inputs)
//	inputs[0..n]: 32*n bytes      (uint256 scalars)
//
// Output: 32 bytes (0x01 = valid proof, 0x00 = invalid proof)
type groth16Verify struct{}

// RequiredGas returns the gas required for Groth16 verification.
// Fixed at 440,000 gas as specified in the zkCross paper.
func (c *groth16Verify) RequiredGas(input []byte) uint64 {
	return params.Groth16VerifyGas
}

// Run executes the Groth16 proof verification.
//
// Verification equation (Groth16):
//
//	e(-A, B) · e(α, β) · e(vk_x, γ) · e(C, δ) = 1
//
// Where vk_x = IC[0] + Σ(IC[i+1] · input[i])
func (c *groth16Verify) Run(input []byte) ([]byte, error) {
	// Fixed header size: proof(256) + vk(448) + numInputs(32) = 736
	// Plus at least IC[0](64) = 800 bytes minimum
	if len(input) < 800 {
		return nil, errBadGroth16Input
	}

	offset := 0

	// Parse Proof A (G1 point): 64 bytes
	proofA, err := newCurvePoint(input[offset : offset+64])
	if err != nil {
		return nil, err
	}
	offset += 64

	// Parse Proof B (G2 point): 128 bytes
	proofB, err := newTwistPoint(input[offset : offset+128])
	if err != nil {
		return nil, err
	}
	offset += 128

	// Parse Proof C (G1 point): 64 bytes
	proofC, err := newCurvePoint(input[offset : offset+64])
	if err != nil {
		return nil, err
	}
	offset += 64

	// Parse VK Alpha (G1 point): 64 bytes
	vkAlpha, err := newCurvePoint(input[offset : offset+64])
	if err != nil {
		return nil, err
	}
	offset += 64

	// Parse VK Beta (G2 point): 128 bytes
	vkBeta, err := newTwistPoint(input[offset : offset+128])
	if err != nil {
		return nil, err
	}
	offset += 128

	// Parse VK Gamma (G2 point): 128 bytes
	vkGamma, err := newTwistPoint(input[offset : offset+128])
	if err != nil {
		return nil, err
	}
	offset += 128

	// Parse VK Delta (G2 point): 128 bytes
	vkDelta, err := newTwistPoint(input[offset : offset+128])
	if err != nil {
		return nil, err
	}
	offset += 128

	// Parse number of public inputs: 32 bytes (uint256)
	if offset+32 > len(input) {
		return nil, errBadGroth16Input
	}
	numInputs := new(big.Int).SetBytes(input[offset : offset+32])
	offset += 32

	// Validate number of inputs (sanity check)
	numInputsInt := int(numInputs.Int64())
	if numInputsInt < 0 || numInputsInt > 100 {
		return nil, errBadGroth16Input
	}

	// Validate remaining input length
	expectedRemaining := (numInputsInt+1)*64 + numInputsInt*32
	if offset+expectedRemaining != len(input) {
		return nil, errBadGroth16Input
	}

	// Parse IC points: (numInputs + 1) G1 points
	ic := make([]*bn256.G1, numInputsInt+1)
	for i := 0; i <= numInputsInt; i++ {
		ic[i], err = newCurvePoint(input[offset : offset+64])
		if err != nil {
			return nil, err
		}
		offset += 64
	}

	// Parse public inputs: numInputs uint256 scalars
	publicInputs := make([]*big.Int, numInputsInt)
	for i := 0; i < numInputsInt; i++ {
		publicInputs[i] = new(big.Int).SetBytes(input[offset : offset+32])
		offset += 32
	}

	// ==========================================
	// Compute vk_x = IC[0] + Σ(IC[i+1] · input[i])
	// ==========================================
	vkX := new(bn256.G1)
	vkX.Unmarshal(ic[0].Marshal())
	for i := 0; i < numInputsInt; i++ {
		term := new(bn256.G1)
		term.ScalarMult(ic[i+1], publicInputs[i])
		sum := new(bn256.G1)
		sum.Add(vkX, term)
		vkX = sum
	}

	// ==========================================
	// Pairing check: e(-A, B) · e(α, β) · e(vk_x, γ) · e(C, δ) = 1
	// ==========================================
	// Negate A: negate the Y coordinate to get -A on the BN254 curve
	marshaledA := proofA.Marshal()
	// BN254 prime field modulus
	fieldModulus, _ := new(big.Int).SetString("30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47", 16)
	negY := new(big.Int).Sub(fieldModulus, new(big.Int).SetBytes(marshaledA[32:64]))
	negABuf := make([]byte, 64)
	copy(negABuf[:32], marshaledA[:32])
	negYBytes := negY.Bytes()
	copy(negABuf[64-len(negYBytes):64], negYBytes)
	negA := new(bn256.G1)
	negA.Unmarshal(negABuf)

	g1Points := []*bn256.G1{negA, vkAlpha, vkX, proofC}
	g2Points := []*bn256.G2{proofB, vkBeta, vkGamma, vkDelta}

	if bn256.PairingCheck(g1Points, g2Points) {
		return true32Byte, nil
	}
	return false32Byte, nil
}

// Name returns the name of the precompiled contract.
func (c *groth16Verify) Name() string {
	return "GROTH16_VERIFY"
}
