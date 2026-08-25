# 20-Million-Constraint Circuit Execution — Manifest

## Five Matching Conditions (TODO §1)

| # | Condition            | Requirement                                               | Status  |
|---|----------------------|-----------------------------------------------------------|---------|
| 1 | Statement            | Verify B_max=15 inner Groth16 proofs + StateTransition    | Pending |
| 2 | Public-input iface   | 3 inputs: cluster commitment, cluster id, round           | Pending |
| 3 | Security level       | 128-bit, BN254                                            | Pending |
| 4 | Toolchain            | Rust/Arkworks with `parallel` feature                     | Pending |
| 5 | Host                 | AsusL40 (Xeon Gold 6538Y+, 16 vCPU, 200 GiB)             | Pending |

## Directory Contents (after run)

| File                    | Description                                    |
|-------------------------|------------------------------------------------|
| `host_info.txt`         | Host identity (uname, lscpu, free)             |
| `build_agg/`            | Circuit artifacts (R1CS, PK, VK)               |
| `constraint_count.txt`  | Constraint count from build step               |
| `identity_hashes.txt`   | SHA-256 of R1CS, PK, VK                        |
| `deps.lock.txt`         | Locked cargo dependency tree                   |
| `witness.bin`           | Generated witness                              |
| `witness.time`          | `/usr/bin/time -v` output for witness gen       |
| `proof_{1,2,3}.bin`     | Three independent proofs                       |
| `prove_{1,2,3}.time`    | `/usr/bin/time -v` output per prove run         |
| `public_1.json`         | Public inputs accepted by the verifier         |
| `manifest.txt`          | Run metadata                                   |
| `measured_summary.json` | Parsed mean/CI (from `parse_20m_results.py`)   |
| `model_validation.csv`  | Prediction error per model form (Table 21)     |
| `e8_pipeline_measured.csv` | Updated E8 pipeline with measured S_agg     |

## Manuscript Updates After Run

1. **Table 8, p.18** — Change 20M row from *Predicted* to *Measured*
2. **Table 19** — Replace interval row with measured mean and CI
3. **Section 7.9, Table 21** — Add model-error column
4. **Section 7.5.1, Tables 14–15** — Recompute worker counts, memory, latency parity
5. **Table 42, Section 8.2** — Recompute +17% and +29% overheads
6. **Abstract, Section 9(1), Section 10** — Remove prediction language

## How to Run

```bash
# On the AsusL40 node:
cd HZKA/scripts/circuit_20m
bash run_20m_circuit.sh

# Then parse results:
python3 parse_20m_results.py
```
