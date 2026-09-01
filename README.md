# H-ZKA: A Hierarchical Zero-Knowledge Architecture for Byzantine-Resilient Cross-Chain Auditing

> Hierarchical ZK-SNARK audit framework with canonical MF-PoP reputation, VRF cluster shuffling, and $O(\sqrt{k})$ global audit workload reduction.

## Table of Contents

- [System Architecture](#system-architecture)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Scripts Reference](#scripts-reference)
- [Experimental Results](#experimental-results)
- [Second-Revision Protocol Experiments](#second-revision-protocol-experiments)
- [Troubleshooting](#troubleshooting)

---

## System Architecture

H-ZKA is organized as a 3-layer audit stack:

- L0 is the chain layer. It contains the ordinary chains, and each chain generates its own local proof for the audited state transition.
- L1 is the cluster layer. It groups chains into $M=\lceil\sqrt{k}\rceil$ clusters, lets each cluster head aggregate the local proofs, and applies the canonical MF-PoP reputation rules to the committers in that cluster.
- L2 is the global audit layer. It verifies one aggregated proof per cluster, maintains the global audit view, and keeps on-chain verification at $O(\sqrt{k})$ instead of $O(k)$.

The point of this layout is to keep local proof generation close to each chain, push batching and reputation decisions to the cluster heads, and leave the global chain with only compact proofs to verify. That is what gives H-ZKA its scale-out behavior without touching the privacy-preserving transfer or exchange protocols.

For the evaluated deployment, the workspace models a 200-node system:

```
┌──────────────────────────────────────────────────────────────────┐
│                      200-Node System                             │
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐       ┌──────────┐     │
│  │   VM 1   │  │   VM 2   │  │   VM 3   │  ...  │  VM 10   │     │
│  │ 10 chains│  │ 10 chains│  │ 10 chains│       │ 10 chains│     │
│  │ 20 nodes │  │ 20 nodes │  │ 20 nodes │       │ 20 nodes │     │
│  └──────────┘  └──────────┘  └──────────┘       └──────────┘     │
│                                                                  │
│  Total: 100 chains × 2 nodes/chain = 200 nodes (Clique PoA)      │
└──────────────────────────────────────────────────────────────────┘
```

| Component | Value |
| --- | --- |
| VMs (Azure) | 10 |
| Chains per VM | 10 |
| Nodes per chain | 2 (Clique PoA) |
| Total chains | 100 |
| Total nodes | 200 |

### Hierarchical H-ZKA View

![H-ZKA Architecture](architecture.png)

The main operating properties are:

- Canonical MF-PoP separates confirmed safety faults from omission-only behavior.
- Six consecutive confirmed safety faults trigger Trust Jail.
- Recurring confirmed safety faults lead to jail within at most $7W$ rounds.
- Omission-only behavior becomes election-ineligible after 69 missed rounds.
- The global audit layer verifies $O(\sqrt{k})$ aggregated proofs per round.

### Port Mapping Per VM

```
Chain 1:  8545 (n1), 8546 (n2)   -> chainId 101
Chain 2:  8547 (n1), 8548 (n2)   -> chainId 102
...
Chain 10: 8563 (n1), 8564 (n2)   -> chainId 110
```

---

## Project Structure

The repository is organized around the implementation and evaluation artifacts. The tree below shows the main files that matter for reproducing the experiments.

```text
HZKA/
├── contracts/
│   ├── audit_chain/
│   │   ├── AuditContract.sol
│   │   ├── AuditContractV2.sol
│   │   ├── ClusterManager.sol
│   │   └── ReputationRegistry.sol
│   ├── ordinary_chain/
│   │   ├── ExchangeContract.sol
│   │   └── TransferContract.sol
│   └── libraries/
│       ├── Denomination.sol
│       └── Groth16Verifier.sol
├── circuits/
│   ├── circom/
│   │   └── HZKA_psi.circom
│   ├── common/
│   ├── phi/
│   ├── psi/
│   └── theta/
├── docker/
│   ├── Dockerfile
│   ├── docker-compose-10vm.yml
│   ├── entrypoint.sh
│   └── .env.vm1 ... .env.vm10
├── geth-patch/
├── relay/
├── scripts/
│   ├── azure_vm_setup.sh
│   ├── deploy_contracts_v2.cjs
│   ├── deploy_global_audit.cjs
│   ├── deploy_sepolia.cjs
│   ├── global_audit_experiment.cjs
│   ├── mfpop_simulation.py
│   ├── network_latency_experiment.sh
│   ├── real_latency_experiment.cjs
│   ├── real_workload_experiment.cjs
│   ├── run_all_experiments.sh
│   ├── run_all_vms_experiments.sh
│   ├── run_azure_scenario1.sh
│   ├── run_benchmark.sh
│   ├── run_benchmark_all.sh
│   ├── run_benchmark_on_vm.sh
│   ├── run_global_audit.sh
│   ├── stop_docker.sh
│   ├── vm_groth16_benchmark.js
│   ├── revision2/
│   │   ├── hzka_protocol_sim.py
│   │   ├── exp_byzantine_churn.py
│   │   ├── exp_adaptive_adversary.py
│   │   ├── exp_clustering_ablation.py
│   │   ├── exp_leakage.py
│   │   ├── exp_fault_recovery.py
│   │   ├── exp_overhead_model.py
│   │   ├── run_all.sh
│   │   └── README.md
│   └── log_run_script/
│       ├── benchmark_azure.log
│       ├── benchmark_local.log
│       ├── deploy_sepolia.log
│       ├── deploy_to_10vm.log
│       ├── global-audit.log
│       ├── run_all_vms_experiments.log
│       ├── run_azure_scenario1.log
│       ├── run_benchmark_all_RapidSNARK.log
│       └── run_benchmark_all_Rust.log
├── result/
│   ├── all_vms/
│   ├── azure_latency/
│   ├── azure_latency_nonfix_TPS/
│   ├── global_audit/
│   ├── network_latency/
│   ├── ram_benchmark/
│   ├── sepolia/
│   ├── revision2/
│   ├── simulation/
│   └── vm_benchmark/
├── zkp/
├── deployment_v2.json
├── deployment_sepolia.json
├── hardhat.config.js
└── package.json
```

Notable benchmark and analysis artifacts:

- `result/vm_benchmark/local_bench.json`
- `result/vm_benchmark/Azure_groth16_bench.json`
- `result/vm_benchmark/groth16_benchmark_extrapolation.json`
- `result/ram_benchmark/groth16_ram_report.json`
- `result/ram_benchmark/groth16_ram_report.csv`
- `result/simulation/raw_mfpop_analysis.json`
- `result/revision2/` (second-revision protocol simulations, E1 to E6)

---

## Prerequisites

| Tool | Version | Purpose |
| --- | --- | --- |
| Node.js | >= 18 | Scripts, Hardhat |
| Python | >= 3.8 | MF-PoP simulation |
| Docker | >= 24 | Local Geth chains |
| Circom | >= 2.1 | Circuit compilation |
| snarkjs | >= 0.7 | Proof generation and verification |
| Rapidsnark | latest | C++ prover for the benchmark suite |

```bash
cd HZKA && npm install
pip install numpy matplotlib
```

---

## Quick Start

### 1. Setup VMs

```bash
ssh -i <key>.pem azureuser@<VM_IP>
cd ~/HZKA
bash scripts/azure_vm_setup.sh
exit
```

### 2. Start Local Chains

```bash
cd ~/HZKA/docker
cp .env.vm1 .env
docker compose -f docker-compose-10vm.yml up -d --build
```

### 3. Deploy Contracts

```bash
VM_ID=1 node scripts/deploy_contracts_v2.cjs
VM_ID=2 node scripts/deploy_contracts_v2.cjs
# ... repeat for all 10 VMs
```

### 4. Reproduce the Logged Runs

```bash
python3 scripts/mfpop_simulation.py > scripts/log_run_script/mfpop_simulation.log
python3 scripts/convergence_simulation.py
node scripts/deploy_sepolia.cjs > scripts/log_run_script/deploy_sepolia.log
bash scripts/run_benchmark_on_vm.sh > scripts/log_run_script/benchmark_azure.log
node scripts/global_audit_experiment.cjs > scripts/log_run_script/global-audit.log
bash scripts/run_all_vms_experiments.sh > scripts/log_run_script/run_all_vms_experiments.log
bash scripts/run_azure_scenario1.sh > scripts/log_run_script/run_azure_scenario1.log
```

---

## Scripts Reference

### Local Machine Scripts

| Script | Purpose | Output |
| --- | --- | --- |
| `scripts/mfpop_simulation.py` | Canonical MF-PoP reputation simulation with slashing and arbitration | `result/simulation/mfpop_reputation_recovery.png`, `result/simulation/mfpop_stake_slashing.png`, `result/simulation/raw_mfpop_analysis.json` |
| `scripts/convergence_simulation.py` | Post-hoc convergence and attacker-isolation analysis | `result/simulation/convergence.png`, `result/simulation/raw_convergence.json` |
| `scripts/deploy_sepolia.cjs` | Deploy contracts to Sepolia and measure on-chain gas | `result/sepolia/sepolia_gas_report.json`, `deployment_sepolia.json` |
| `scripts/run_benchmark.sh` | Small benchmark driver for local proof timing | `result/vm_benchmark/local_bench.json` |

### VM and Benchmark Scripts

| Script | Purpose | Output |
| --- | --- | --- |
| `scripts/deploy_contracts_v2.cjs` | Deploy ReputationRegistry, ClusterManager, and AuditContractV2 to local chains | `deployment_v2.json` |
| `scripts/deploy_global_audit.cjs` | Deploy contracts for the global audit experiment | `result/global_audit/deployment_global_audit.json` |
| `scripts/real_workload_experiment.cjs` | TN2: verify the $O(k)$ to $O(\sqrt{k})$ workload reduction | `result/all_vms/vmX/` |
| `scripts/real_latency_experiment.cjs` | TN3: end-to-end audit latency experiment | `result/all_vms/vmX/` |
| `scripts/network_latency_experiment.sh` | Scenario 1: latency and loss injection | `result/network_latency/` |
| `scripts/global_audit_experiment.cjs` | Global audit rounds across 100 chains | `result/global_audit/global_audit_report.json`, `global_audit_rounds.csv` |
| `scripts/vm_groth16_benchmark.js` | Groth16 Rapidsnark benchmark driver | `result/vm_benchmark/` |
| `scripts/run_benchmark_on_vm.sh` | Single-VM benchmark runner used for the Azure log | `scripts/log_run_script/benchmark_azure.log` |
| `scripts/run_benchmark_all.sh` | Extended benchmark sweep used for the regression fit | `scripts/log_run_script/run_benchmark_all_RapidSNARK.log`, `scripts/log_run_script/run_benchmark_all_Rust.log` |

### Orchestration Scripts

| Script | Purpose |
| --- | --- |
| `scripts/deploy_to_10vm.sh` | Deploy code and Docker assets to all 10 VMs |
| `scripts/setup_10vm_network.sh` | Set up the multi-VM network topology |
| `scripts/run_all_vms_experiments.sh` | Run TN2 and TN3 across all VMs |
| `scripts/run_all_experiments.sh` | End-to-end master script |
| `scripts/run_azure_experiments.sh` | Azure-specific experiment runner |
| `scripts/run_azure_scenario1.sh` | Network latency scenario |
| `scripts/run_global_audit.sh` | Deploy and run the global audit experiment |
| `scripts/stop_docker.sh` | Stop all Docker containers |

### Log Run Scripts

The repository keeps paper-relevant logs under `scripts/log_run_script/`:

| Log file | Purpose |
| --- | --- |
| `scripts/log_run_script/benchmark_azure.log` | Azure Rapidsnark benchmark log |
| `scripts/log_run_script/benchmark_local.log` | Local Rapidsnark benchmark log |
| `scripts/log_run_script/run_benchmark_all_RapidSNARK.log` | Extended C++ benchmark sweep used for the regression fit |
| `scripts/log_run_script/run_benchmark_all_Rust.log` | Rust-prover comparison run |
| `scripts/log_run_script/deploy_sepolia.log` | Sepolia deployment and gas measurement log |
| `scripts/log_run_script/deploy_to_10vm.log` | 10-VM deployment log |
| `scripts/log_run_script/global-audit.log` | Global audit round log |
| `scripts/log_run_script/run_all_vms_experiments.log` | TN2 and TN3 multi-VM log |
| `scripts/log_run_script/run_azure_scenario1.log` | Network latency scenario log |

### Second-revision protocol simulations

| Path | Purpose |
| --- | --- |
| `scripts/revision2/hzka_protocol_sim.py` | Core discrete-round simulator: canonical MF-PoP transition, capacitated k-medoid formation, capped VRF election, calibrated audit-layer network model |
| `scripts/revision2/exp_byzantine_churn.py` | E1: Byzantine ratio, churn, outage length, latency and loss sweeps; partition study |
| `scripts/revision2/exp_adaptive_adversary.py` | E2: six adversarial strategies, fault ceiling |
| `scripts/revision2/exp_clustering_ablation.py` | E3: eta sweep and five-policy clustering ablation |
| `scripts/revision2/exp_leakage.py` | E4: audit-layer metadata leakage (mutual information, adversary advantage) |
| `scripts/revision2/exp_fault_recovery.py` | E5: cluster-head failure, blast radius, failover cost |
| `scripts/revision2/exp_overhead_model.py` | E6: per-stage communication, storage, and prover-memory accounting |
| `scripts/revision2/run_all.sh` | Reproduce E1 to E6 end to end |
| `scripts/revision2/README.md` | Full description, parameters, and headline results |

---

## Experimental Results

The values below are aligned with the claims in `main.tex`.

### TN1 - MF-PoP Reputation Convergence (RQ2)

- Canonical outcome: six consecutive confirmed safety faults trigger Trust Jail.
- Recurring confirmed safety faults trigger jail within at most $7W$ rounds.
- Omission-only behavior becomes election-ineligible after 69 missed rounds.

### TN2 - Audit Workload Reduction (RQ1)

| k (chains) | M = sqrt(k) | Original proofs | H-ZKA proofs | Reduction |
| --- | --- | --- | --- | --- |
| 25 | 5 | 25 | 5 | 5.0x |
| 50 | 8 | 50 | 8 | 6.3x |
| 100 | 10 | 100 | 10 | 10.0x |
| 150 | 13 | 150 | 13 | 11.5x |
| 200 | 15 | 200 | 15 | 13.3x |

### TN3 - Latency and Throughput (RQ4)

| k (chains) | M = sqrt(k) | Original latency | H-ZKA latency | Speedup |
| --- | --- | --- | --- | --- |
| 25 | 5 | 10.00 s | 1.65 s | 6.1x |
| 50 | 8 | 20.00 s | 2.64 s | 7.6x |
| 100 | 10 | 40.00 s | 3.31 s | 12.1x |
| 150 | 13 | 60.00 s | 4.29 s | 14.0x |
| 200 | 15 | 80.00 s | 4.96 s | 16.1x |

### TN4 - Gas Consumption (RQ4)

> **Important:** the per-cluster figure below was recorded with
> `enableMockVerifier()` active (see `scripts/deploy_global_audit.cjs`), so it
> measures contract bookkeeping, calldata, storage, and events **only**. The
> Groth16 check was bypassed. It cannot be read as end-to-end verification
> cost, and the earlier 13.8x end-to-end claim derived from it has been
> withdrawn.

Measured contract bookkeeping:

| Measurement | Gas | Includes proof verification? |
| --- | --- | --- |
| Individual audit (Psi) | 555,202 | see caveat above |
| Aggregated submission bookkeeping | 324,145 | **no** (verifier mocked) |
| Reputation update + slashing | 772,621 | n/a |

Verification cost is instead derived exactly from the EVM gas schedule by
`scripts/revision2/exp_onchain_cost.py`, using constants fixed by EIP-196/197
(repriced by EIP-1108), EIP-2028, and EIP-2929/3529:

| Interface | Public inputs | Verify gas | Round total at k=100 |
| --- | --- | --- | --- |
| Flat, per chain | 3 | 204,450 | 24.25 Mgas |
| H-ZKA, cluster commitment | 3 | 204,450 | 2.43 Mgas (10.0x less) |
| H-ZKA, per-chain public inputs | 17 | 290,550 | 3.35 Mgas (7.2x less) |

The third row is why Algorithm 1 was corrected to publish a constant-size
cluster commitment: exposing every member root keeps the pairing count at
O(sqrt k) but makes the scalar-multiplication and calldata terms Theta(k).

The internal source artifacts for these numbers are:

| Value family | Source artifact |
| --- | --- |
| Deploy gas and deploy cost | `result/sepolia/sepolia_gas_report.json` |
| Per-round global audit gas and latency | `result/global_audit/global_audit_report.json`, `result/global_audit/global_audit_rounds.csv`, `scripts/log_run_script/global-audit.log` |

The verification reduction is 10.0x at k=100 and 13.3x at k=200 under the
commitment interface. The exact per-round internal CSV/log values vary slightly
by round.

### Benchmark Regression and Capacity Model

- The paper's benchmark regression uses nine measured circuits up to 11.5 million constraints.
- A size- and interface-matched profiling circuit at the deployed scale of 20,014,400 constraints
  measures $122.54\pm9.00$ s, which falls at the top of the $[54.6, 122.5]$ s interval predicted
  across three model forms. The inner-verification constraint load is represented rather than
  fully implemented, so this bounds resource provisioning rather than demonstrating a complete
  recursive verifier.
- Under a 120 s audit cadence and counting **both** proving stages, H-ZKA needs
  58 workers at k=100 against the flat baseline's 47: the same 47 inner-proof
  workers plus 11 aggregation workers. The earlier "8 instead of 47" comparison
  omitted the k per-chain proofs that H-ZKA also requires. See
  `scripts/revision2/exp_prover_pipeline.py`.
- The artifact set for these runs is stored under `result/vm_benchmark/`, `result/ram_benchmark/`, and `scripts/log_run_script/`.

### TN6 - Byzantine Resilience (RQ2)

| Byzantine fraction | Initial accuracy | Final accuracy |
| --- | --- | --- |
| 0% | 100% | 100% |
| 10% | 90% | 100% |
| 20% | 80% | 100% |
| 30% | 70% | 100% |
| 40% | 60% | 100% |

### Result Summary

| Experiment | Key claim |
| --- | --- |
| TN1 | 6 confirmed safety faults to jail; 69 rounds for omission-only ineligibility |
| TN2 | 10x proof reduction at k=100 |
| TN3 | 12.1x speedup at k=100 |
| TN4 | 10.0x on-chain verification gas reduction at k=100 (exact gas model) |
| Benchmark regression | 20M proof measured at $122.54\pm9.00$ s; predicted interval [54.6, 122.5] s |
| Capacity | 58 H-ZKA workers vs 47 flat at k=100, counting both proving stages |
| TN6 | 100% final accuracy within the per-cluster BFT condition |

---

## Second-Revision Protocol Experiments

Seeded discrete-round simulations of the audit layer, added for the second
revision. They are protocol simulations calibrated to the same `tc/netem`
profile as the measured coordination results, not hardware measurements; the
proving, gas, and coordination numbers above are unchanged by them.

Reproduce everything with:

```bash
cd HZKA/scripts/revision2
bash run_all.sh
```

Base seed `20260822`, 30 seeds per cell. Outputs land in `result/revision2/`.
See `scripts/revision2/README.md` for the full parameter set.

### TN8 - Fault ceiling and adaptive adversaries

- No strategy, adaptive or patient, lands more than six confirmed safety faults
  before the absorbing jail; the seventh always triggers it.
- The strongest evader forfeits 46.9% of stake and must perform 158 consecutive
  honest rounds to buy its sixth fault, after which its election weight is
  capped at 1.6% of an honest committer's.
- Replayed against a convex-only update with no safety multiplier, the same
  periodic schedule leaves the attacker at 82.0% of honest election weight.

### TN8b - Corrections applied after Associate Editor review

Four results published in an earlier state of this repository were corrected.
Both the old and new values are recorded here so that anyone who cloned the
earlier state can see what changed.

| Quantity | Earlier | Corrected | Cause |
| --- | --- | --- | --- |
| Prover workers at k=100 | 8 vs 47 (83% fewer) | 58 vs 47 (23% more) | The earlier model omitted the k per-chain proofs H-ZKA also requires |
| On-chain gas reduction | 13.8x (measured) | 10.0x (exact model) | The measured run had `enableMockVerifier()` active, so no proof was verified |
| Metadata leakage reduction | 56.9x | 3.0x worst case | The flat baseline had a variable-size circuit, which Groth16 does not permit |
| Byzantine recovery | full at 50% | conditioned on the per-cluster BFT bound | Captured clusters were not modelled and can censor adjudication |

See `HZKA/scripts/revision2/README.md` for the reproduction commands behind
each corrected value.

### TN9 - Byzantine ratio, churn, and partitions

| Byzantine % | Honest weight share, round 1 | Round 5 | Honest heads, round 1 | Round 5 |
| --- | --- | --- | --- | --- |
| 10% | 0.9478 | 0.9964 | 0.873 | 0.990 |
| 20% | 0.8882 | 0.9919 | 0.777 | 0.977 |
| 30% | 0.8226 | 0.9862 | 0.717 | 0.980 |
| 40% | 0.7482 | 0.9788 | 0.613 | 0.937 |
| 50% | 0.6659 | 0.9688 | 0.470 | 0.883 |

Both quantities reach 1.000 by round 10 at every ratio **within the
per-cluster BFT condition**. That condition is the binding constraint: it fails
for 1.8 of 10 clusters at a 20% global Byzantine ratio, and a cluster that
breaks it can censor adjudication. See `exp_bft_bound.py`. Across 900 churn
runs and 720 partition runs, including 120-round outages, zero honest
committers were jailed and zero honest stake was slashed. Election ineligibility begins at
exactly 69 consecutive missed rounds at the default `r_0 = 0.5` and 76 for an
established committer; one valid submission restores it in every case.

### TN10 - Collusion

| Colluders | Population share | Head-capture rate |
| --- | --- | --- |
| 10 | 10% | 0.0033 |
| 20 | 20% | 0.0082 |
| 30 | 30% | 0.0154 |
| 40 | 40% | 0.0241 |

Capture is strongly sub-proportional: a 40% coalition takes 2.41% of
cluster-head slots, a factor of 16.6 below its population share.

### TN11 - Clustering ablation

| Policy | Intra-cluster RTT | Tx-cut ratio | Coordination |
| --- | --- | --- | --- |
| Random, balanced | 219.5 ms | 0.909 | 873.4 ms |
| Flow only (eta = 0) | 181.9 ms | 0.670 | 829.3 ms |
| k-medoid (eta = 0.50) | 144.1 ms | 0.645 | 679.3 ms |
| k-medoid (eta = 0.75) | 104.3 ms | 0.704 | 620.1 ms |
| RTT only (eta = 1) | 62.7 ms | 0.837 | 530.1 ms |

A balanced random partition is dominated on every axis.

### TN12 - Audit-layer metadata leakage

| Publication pattern | Leak (bits) | Share of H(S) | Adversary bal. acc. |
| --- | --- | --- | --- |
| Flat, per chain | 0.9847 | 98.5% | 0.997 |
| Hierarchical, per-chain public inputs | 0.9843 | 98.4% | 0.997 |
| Hierarchical, cluster commitment | 0.0001 | 0.01% | 0.500 |

All arms use a fixed-shape circuit and a constant 127-byte proof, so timing and
artifact size are identical by construction. Chance is 0.500. Hierarchical
aggregation with per-chain public inputs leaks exactly as much as flat
publication; only the constant-size cluster commitment changes anything.

**Leakage boundary:** The reduction ranges from $3.0\times$ to $10^3\times$ for an observer
reading the global chain, but is $1.0\times$ for an observer reading data-availability roots.
The worst-case reduction claimed in the abstract is therefore $3.0\times$, which holds
for sparse activity and small clusters.

### TN13 - Fault recovery and failure concentration

| p(crash) | Coordination | Lost rounds | Stalled s.d., H-ZKA / flat |
| --- | --- | --- | --- |
| 0.01 | 884 ms | 0.0000 | 3.30 / 1.00 |
| 0.05 | 1,021 ms | 0.0004 | 7.43 / 2.16 |
| 0.10 | 1,184 ms | 0.0131 | 10.01 / 3.02 |
| 0.20 | 1,595 ms | 0.0850 | 13.57 / 4.08 |

Columns are crash probability, coordination latency, lost-round fraction, and
stalled-chain standard deviation (H-ZKA / flat). A submission attempt has a
3 s deadline and a round has the 120 s cadence as its budget; a cluster gets
three attempts. Coordination never exceeds 1.4% of the round budget, but
rounds are lost when a cluster exhausts its attempts. The stalled-chain mean is
unchanged versus flat; the standard deviation is 3.3x higher, which is the
structural cost of hierarchy.

### TN14 - Communication and storage

| k | On-chain B/round, flat | H-ZKA | Ratio | Storage GiB/yr, flat | H-ZKA |
| --- | --- | --- | --- | --- | --- |
| 25 | 6,496 | 1,386 | 4.7x | 0.97 | 0.20 |
| 100 | 25,696 | 2,676 | 9.6x | 3.89 | 0.39 |
| 200 | 51,296 | 3,966 | 12.9x | 7.78 | 0.59 |

---

## Troubleshooting

### Docker Permission Denied

```bash
sudo usermod -aG docker $USER
newgrp docker
```

### Containers Not Starting

```bash
docker compose -f docker-compose-10vm.yml logs
```

### Check Chain Connectivity

```bash
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:8545
```

### Sepolia: Insufficient Funds

```bash
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x...","latest"],"id":1}' \
  https://rpc.sepolia.org
```

### Stop All Docker Containers

```bash
bash scripts/stop_docker.sh
```

---

## Deployed Contracts

### Sepolia Testnet

| Contract | Address |
| --- | --- |
| ReputationRegistry | `0xEe2559828b9C26DdAB486828BaA32d961F54A5b3` |
| ClusterManager | `0x6482A13dc1d312188B60E3b2fA205347F12659dE` |
| AuditContractV2 | `0x212cf16E53356DA0f9ff4c99617313729eDd45f2` |

### Local VM1 Example

| Contract | Address |
| --- | --- |
| ReputationRegistry | `0xfCfb0454c9F2CFB96C798C01aFEeb94d8E35D335` |
| ClusterManager | `0xe54c7Aa4dbaf3bCF8B85b3E5423210B1292d8208` |
| AuditContractV2 | `0xeC3B45E8216218617D35BB50a26bC09912d68584` |

---

## Tech Stack

| Layer | Technology |
| --- | --- |
| Blockchain | Go-Ethereum (Clique PoA) |
| Smart contracts | Solidity 0.8.x |
| ZK circuits | Circom 2 + snarkjs |
| C++ prover | Rapidsnark |
| Deployment | Hardhat + ethers.js v6 |
| Simulation | Python (NumPy, Matplotlib) |
| Containers | Docker Compose |
| Cloud | Azure VMs (10x) |

---

## License

Academic research project - UIT (University of Information Technology).