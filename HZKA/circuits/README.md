# H-ZKA Circuit Artifacts

This directory contains the zero-knowledge circuit definitions and related artifacts for the H-ZKA protocol.

## Circuit Organization

```
circuits/
├── agg.r1cs                    # Aggregation skeleton (empty file)
├── circom/                     # Circom source definitions
│   └── HZKA_psi.circom        # Per-chain audit circuit definition
├── common/                     # Shared constraints and utilities
├── phi/                        # Exchange protocol private inputs
├── psi/                        # Per-chain audit circuits
└── theta/                      # Aggregation inner-verification representation
```

## Key Artifacts

### agg.r1cs

**Status:** Intentionally empty (0 bytes)  
**SHA-256:** `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`  
**Purpose:** Placeholder file documenting the aggregation circuit interface

The empty `agg.r1cs` file represents the aggregation verification circuit that is used in H-ZKA's hierarchical proof composition. Its hash is intentionally documented as the SHA-256 of an empty string, consistent with the paper's treatment where the inner-verification constraint load is represented rather than fully implemented.

This design choice allows:
- Clean separation of concerns between per-chain proofs and aggregation
- Precise measurement of on-chain verification costs (fixed gas per cluster)
- Upper-bound resource provisioning estimates
- Transparent documentation that this component is a specification point

### psi/ - Per-Chain Audit Circuit

Contains the Circom definitions for the privacy-preserving per-chain audit circuit used by each ordinary chain to generate local proofs of transaction validity and state transitions.

### theta/ - Aggregation Verification

Contains the representation of inner-verification constraints used in the recursive proof aggregation layer (L1).

### phi/ - Exchange Protocol

Contains the private-input circuit definitions for the privacy-preserving exchange protocol (outside H-ZKA's scope but packaged with the audit layer).

## Constraint Metrics

From the paper's experimental evaluation:

| Circuit | Constraints | Purpose |
| --- | --- | --- |
| Per-chain (psi) | 11,763,593 | Single chain audit per round |
| Aggregation (theta, represented) | 20,014,400 | Cluster-level recursive aggregation |
| Size- and interface-matched profiling | 20,014,400 | Measured in paper at 122.54±9.00 s |

## Building Circuits

```bash
cd circuits
circom circom/HZKA_psi.circom --r1cs --wasm
```

Refer to the main HZKA `README.md` and `hardhat.config.js` for full build instructions.

## Verification

To verify circuit artifacts and their checksums:

```bash
sha256sum -c ../SHA256SUMS
```

The agg.r1cs checksum should be:
```
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  circuits/agg.r1cs
```
