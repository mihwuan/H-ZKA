# zkCross Circuit Compilation Guide

## Overview

The zkCross circuits are written as Java classes extending xjsnark's `CircuitGenerator`. The compilation pipeline is:

```
Java Circuit (.java)
    │
    ▼
xjsnark (JetBrains MPS IDE)
    │  Translates high-level operations to R1CS constraints
    ▼
Arithmetic Circuit (.arith + .in files)
    │
    ▼
libsnark (C++ backend)
    │  Groth16 setup / prove / verify
    ▼
Proof (π) + Verification Key (vk)
```

## Step 1: Setup xjsnark

xjsnark is a JetBrains MPS-based DSL. It lives in `../xjsnark/`.

### Opening the Project

1. Install JetBrains MPS (version compatible with xjsnark — see `xjsnark/README.md`)
2. Open MPS → File → Open → select `../xjsnark/` directory
3. The project contains the `xjsnark` language definition and example circuits

### Understanding Circuit Structure

Each circuit extends `CircuitGenerator` and implements these lifecycle methods (in order):

```java
public class MyCircuit extends CircuitGenerator {
    // 1. Constructor - set circuit name
    public MyCircuit(String name) { super(name); }

    // 2. Define public inputs
    protected void __defineInputs() {
        // UnsignedInteger.createInputArray(circuitOwner, bitWidth, count, name)
    }

    // 3. Define public outputs (optional)
    protected void __defineOutputs() { }

    // 4. Define private witness values
    protected void __defineWitnesses() {
        // UnsignedInteger.createWitnessArray(circuitOwner, bitWidth, count, name)
    }

    // 5. Define witnesses with automatic range verification
    protected void __defineVerifiedWitnesses() { }

    // 6. Main circuit logic
    protected void outsource() {
        // All constraint generation happens here
        // Use operations like .add(), .xorBitwise(), etc.
    }
}
```

### Type System

| xjsnark Type           | Description                  | Usage                       |
| ---------------------- | ---------------------------- | --------------------------- |
| `UnsignedInteger`      | Fixed-width unsigned integer | All arithmetic              |
| `createInputArray()`   | Public input array           | Circuit public data         |
| `createWitnessArray()` | Private witness array        | Circuit private data        |
| `.add()`               | Addition                     | Balance computation         |
| `.subtract()`          | Subtraction                  | Balance update              |
| `.xorBitwise()`        | Bitwise XOR                  | Independent preimage scheme |
| `.isEqualTo()`         | Equality assertion           | Constraint enforcement      |

## Step 2: Circuit Files

### Circuit Inventory

| File                                       | Circuit     | Protocol | Description                 |
| ------------------------------------------ | ----------- | -------- | --------------------------- |
| `circuits/common/SHA256Circuit.java`       | SHA-256     | All      | Hash computation inside ZKP |
| `circuits/common/MerkleTreeCircuit.java`   | Merkle Tree | Θ, Φ, Ψ  | Tree operations for SPV     |
| `circuits/theta/TransferCircuit.java`      | Λ_Θ         | Θ        | Cross-chain transfer        |
| `circuits/phi/ExchangePrepareCircuit.java` | Λ^off_Φ     | Φ        | Off-chain exchange prepare  |
| `circuits/phi/ExchangeUnlockCircuit.java`  | Λ^on_Φ      | Φ        | On-chain exchange unlock    |
| `circuits/psi/AuditCircuit.java`           | Λ_Ψ         | Ψ        | Cross-chain auditing        |

### Importing Circuits into xjsnark

1. In MPS, create a new Solution under the xjsnark project
2. Create models matching the package structure (`circuits.common`, `circuits.theta`, etc.)
3. Copy the Java logic into xjsnark circuit nodes
4. xjsnark will translate the operations into R1CS automatically

**Note:** xjsnark uses MPS's projectional editor, so you define circuits through the IDE's DSL interface rather than editing raw Java. The `.java` files in this project serve as the specification — translate them into xjsnark nodes.

## Step 3: Generate R1CS

Once circuits are defined in xjsnark:

1. Right-click the circuit node in MPS
2. Select **Build** → **Generate**
3. xjsnark produces:
   - `<circuit_name>.arith` — Arithmetic circuit (R1CS constraints)
   - `<circuit_name>.in` — Input assignment template

### Generated File Format

The `.arith` file contains lines like:

```
total <num_wires>
input <wire_id>          # public input
nizkinput <wire_id>      # private witness
output <wire_id>         # public output
<gate_type> in <w1> <w2> out <w3>   # constraint gate
```

## Step 4: Groth16 with libsnark

### Install libsnark

```bash
# Clone and build libsnark
git clone https://github.com/scipr-lab/libsnark.git
cd libsnark
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

### Trusted Setup (One-Time per Circuit)

```bash
# Generates proving key (pk) and verification key (vk)
./libsnark/build/libsnark/jsnark_interface/run_ppzksnark setup \
    circuits/theta/TransferCircuit.arith \
    circuits/theta/TransferCircuit.pk \
    circuits/theta/TransferCircuit.vk
```

This must be done for each circuit:

- `TransferCircuit` (Λ_Θ)
- `ExchangePrepareCircuit` (Λ^off_Φ)
- `ExchangeUnlockCircuit` (Λ^on_Φ)
- `AuditCircuit` (Λ_Ψ)

### Prove (Per Transaction)

```bash
# Inputs: .arith file + proving key + witness assignment
# Output: proof binary
./libsnark/build/libsnark/jsnark_interface/run_ppzksnark prove \
    circuits/theta/TransferCircuit.arith \
    circuits/theta/TransferCircuit.pk \
    circuits/theta/TransferCircuit_witness.in \
    proof_theta.bin
```

### Verify (Off-Chain Test)

```bash
./libsnark/build/libsnark/jsnark_interface/run_ppzksnark verify \
    circuits/theta/TransferCircuit.vk \
    proof_theta.bin \
    public_inputs.bin
```

### On-Chain Verification

The proof and VK are encoded and sent to the Groth16 precompile at address `0x20`:

```
Input layout (bytes):
[  0.. 63] Proof.A (G1 point, 64 bytes)
[ 64..191] Proof.B (G2 point, 128 bytes)
[192..255] Proof.C (G1 point, 64 bytes)
[256..319] VK.alpha (G1 point, 64 bytes)
[320..447] VK.beta (G2 point, 128 bytes)
[448..575] VK.gamma (G2 point, 128 bytes)
[576..703] VK.delta (G2 point, 128 bytes)
[704..735] numInputs (uint256)
[736..736+n*64-1] IC points (n+1 G1 points)
[736+n*64..] Public inputs (n uint256 values)
```

Output: `0x01` (valid) or `0x00` (invalid), 32 bytes.

## Step 5: Extract Verification Key for Contracts

After trusted setup, extract the VK and format it for the Solidity contracts:

```javascript
// Example: Parse libsnark VK output and format for contract deployment
const vk = {
  alpha: { x: "0x...", y: "0x..." }, // G1
  beta: { x: ["0x...", "0x..."], y: ["0x...", "0x..."] }, // G2
  gamma: { x: ["0x...", "0x..."], y: ["0x...", "0x..."] }, // G2
  delta: { x: ["0x...", "0x..."], y: ["0x...", "0x..."] }, // G2
  ic: [
    { x: "0x...", y: "0x..." }, // IC[0]
    { x: "0x...", y: "0x..." }, // IC[1]
    // ... one per public input + 1
  ],
};

// Deploy contract with VK
await transferContract.setVerificationKey(
  [vk.alpha.x, vk.alpha.y],
  [
    [vk.beta.x[0], vk.beta.x[1]],
    [vk.beta.y[0], vk.beta.y[1]],
  ],
  [
    [vk.gamma.x[0], vk.gamma.x[1]],
    [vk.gamma.y[0], vk.gamma.y[1]],
  ],
  [
    [vk.delta.x[0], vk.delta.x[1]],
    [vk.delta.y[0], vk.delta.y[1]],
  ],
  vk.ic.map((p) => [p.x, p.y]),
);
```

## Circuit Constraint Counts

| Circuit           | Approximate Constraints | Prove Time | Verify Time |
| ----------------- | ----------------------- | ---------- | ----------- |
| Λ_Θ (Transfer)    | ~175,000                | ~1.2s      | ~5ms        |
| Λ^off_Φ (Prepare) | ~160,000                | ~1.1s      | ~5ms        |
| Λ^on_Φ (Unlock)   | ~185,000                | ~1.3s      | ~5ms        |
| Λ_Ψ (Audit, ℓ=50) | ~5,880,000              | ~50s       | ~5ms        |

**Note:** Groth16 verification time is constant regardless of circuit size — the verifier only checks a pairing equation.

## Troubleshooting

### Common Issues

1. **xjsnark MPS version mismatch**: Check `xjsnark/README.md` for the required MPS version
2. **libsnark build fails**: Ensure `libgmp-dev`, `libprocps-dev`, `libboost-all-dev` are installed
3. **Circuit too large for memory**: Λ_Ψ with ℓ=50 requires ~8GB RAM for proving (ℓ=100 needs ~16GB). Reduce ℓ for testing.
4. **Proof fails on-chain**: Ensure point encoding matches bn256 (big-endian, 32 bytes per coordinate)
5. **Wrong curve**: xjsnark/libsnark uses bn128 (alt_bn128) which is the same as bn256 in go-ethereum
