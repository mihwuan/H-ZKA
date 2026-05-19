# Paper-Aligned R1CS Circuit Files

Place compiled R1CS files from xjsnark/libsnark here to use the `--profile=paper` setup.

## Required Files

| File | Circuit | Constraints | Public Inputs | Description |
|------|---------|-------------|---------------|-------------|
| `theta_mint.r1cs` | Λ_Θ | ~175,000 | 4 (fpk_R, sn, amount, merkleRoot) | Privacy-preserving transfer (mint) |
| `theta_redeem.r1cs` | Λ_Θ | ~175,000 | 4 (fpk_S, sn, amount, hashCommitment) | Privacy-preserving transfer (redeem) |
| `phi_prepare.r1cs` | Λ^off_Φ | ~160,000 | 5 (pre_I, pre_II, Z_256, hashLock_I, hashLock_II) | Cross-chain exchange (off-chain prepare) |
| `phi_unlock.r1cs` | Λ^on_Φ | ~185,000 | 3 (serialNumber, amount, merkleRoot) | Cross-chain exchange (on-chain unlock) |
| `psi_audit.r1cs` | Λ_Ψ | ~2,800,000 | 2 (oldStateRoot, newStateRoot) | Cross-chain auditing |

## How to Build

1. Install xjsnark (Java-based circuit compiler):
   See `xjsnark/doc/` in the project root for setup instructions.

2. Compile circuits from the paper's xjsnark source:
   ```bash
   cd xjsnark/languages/xjsnark
   java -jar xjsnark.jar circuits/theta_circuit.java
   java -jar xjsnark.jar circuits/phi_prepare_circuit.java
   java -jar xjsnark.jar circuits/phi_unlock_circuit.java
   java -jar xjsnark.jar circuits/psi_audit_circuit.java
   ```

3. Convert libsnark R1CS to snarkjs-compatible format using `r1csfile` library.

4. Copy the `.r1cs` files to this directory (`zkp/paper_r1cs/`).

5. Run setup with paper profile:
   ```bash
   node scripts/setup_zkp.mjs --profile=paper
   ```

## Reference

- zkCross paper Section 5 (Protocol definitions and circuit logic)
- Circuit diagrams: Figures 3, 4, 5, 8
- Performance: Section 6, Tables 2-4
- Gas consumption: Θ=494,000, Φ=901,472, Ψ=466,520
