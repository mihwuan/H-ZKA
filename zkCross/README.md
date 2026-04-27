# zkCross v2 — 200-Node Multi-VM System

> Cross-chain privacy-preserving auditing with MF-PoP reputation and hierarchical clustering.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    200-Node System                               │
│                                                                 │
│  ┌──────────┐  ┌──────────┐       ┌──────────┐                   │
│  │   VM 1   │  │   VM 2   │  ...  │  VM 10   │                   │
│  │ 10 chains│  │ 10 chains│       │ 10 chains│                   │
│  │ 20 nodes│  │ 20 nodes│       │ 20 nodes│                   │
│  │Chain 1-10│  │Chain 11-20│      │Chain 91-100│                 │
│  └──────────┘  └──────────┘       └──────────┘                   │
│                                                                 │
│  Total: 100 chains, 200 nodes                                    │
└─────────────────────────────────────────────────────────────────┘
```

| Component           | Value          |
| ------------------- | -------------- |
| **VMs**             | 10             |
| **Chains per VM**   | 10             |
| **Nodes per chain** | 2 (Clique PoA) |
| **Total chains**    | 100            |
| **Total nodes**     | 200            |

---

## Where to Run Each Script

| Script                                  | Run Where           | Purpose                                         |
| --------------------------------------- | ------------------- | ----------------------------------------------- |
| `scripts/mfpop_simulation.py`           | **LOCAL**           | TN1 + Scenario 4: MF-PoP game theory simulation |
| `scripts/groth16_ram_benchmark.cjs`     | **LOCAL**           | Scenario 3: RAM micro-benchmark                 |
| `scripts/deploy_sepolia.cjs`            | **LOCAL**           | Scenario 2: Deploy to Sepolia, measure REAL gas |
| `scripts/azure_vm_setup.sh`             | **Each VM**         | Setup Docker, Node.js                           |
| `scripts/docker-compose-10vm.yml`       | **Each VM**         | Start 10 local chains                           |
| `scripts/deploy_contracts_v2.cjs`       | **Each VM**         | Deploy to local chains                          |
| `scripts/real_workload_experiment.cjs`  | **Each VM**         | TN2: Workload reduction                         |
| `scripts/real_latency_experiment.cjs`   | **Each VM**         | TN3: Latency measurement                        |
| `scripts/network_latency_experiment.sh` | **Each VM (Linux)** | Scenario 1: tc/netem latency                    |

---

## Quick Start

### Step 1: Setup VMs (run on each VM)

```bash
# SSH to each VM and run setup
ssh -i VM_key.pem azureuser@<VM_IP>
cd ~/zkCross
bash scripts/azure_vm_setup.sh
exit  # Relogin for Docker permissions
```

### Step 2: Start Local Chains (on each VM)

```bash
# On VM1
cd ~/zkCross/docker
cp .env.vm1 .env
docker compose -f docker-compose-10vm.yml up -d --build

# Repeat on VM2-VM10 with .env.vm2, .env.vm3, etc.
```

### Step 3: Deploy Contracts (on each VM)

```bash
# On VM1 (chains 101-110)
cd ~/zkCross
VM_ID=1 node scripts/deploy_contracts_v2.cjs

# On VM2 (chains 201-210)
VM_ID=2 node scripts/deploy_contracts_v2.cjs

# ... repeat for all VMs
```

### Step 4: Run Experiments

```bash
# TN1 + Scenario 4: Game theory simulation (RUN ON LOCAL)
python scripts/mfpop_simulation.py

# Scenario 2: Sepolia deployment (RUN ON LOCAL)
# First: get Sepolia ETH from https://www.sepoliafaucet.io/
echo "SEPOLIA_RPC_URL=https://rpc.sepolia.org" > .env
echo "DEPLOYER_PRIVATE_KEY=0x_your_key" >> .env
node scripts/deploy_sepolia.cjs

# Scenario 3: RAM benchmark (RUN ON LOCAL)
node scripts/groth16_ram_benchmark.cjs

# TN2 + TN3: On each VM (after Docker is running)
cd ~/zkCross
VM_ID=1 node scripts/real_workload_experiment.cjs
VM_ID=1 node scripts/real_latency_experiment.cjs

# Scenario 1: Network latency (RUN ON EACH VM - Linux only)
bash scripts/network_latency_experiment.sh
```

---

## Detailed Run Instructions

### LOCAL Machine (3 scripts)

These run on your **local machine** - no VMs needed:

#### 1. mfpop_simulation.py — TN1 + Scenario 4

```
Purpose:    Simulate MF-PoP reputation with oscillating Byzantine attack
             Prove B3 fix effectiveness (slashing + arbitration)
Location:   LOCAL
Output:     results/mfpop_reputation_recovery.png
            results/mfpop_stake_slashing.png
            results/mfpop_simulation_data.json
Run:        python scripts/mfpop_simulation.py
```

#### 2. groth16_ram_benchmark.cjs — Scenario 3

```
Purpose:    Measure RAM consumption during Groth16 proof generation
             Different circuit sizes: 0.5M to 16M constraints
Location:   LOCAL
Output:     results/ram_benchmark/groth16_ram_report.json
            results/ram_benchmark/groth16_ram_report.csv
Run:        node scripts/groth16_ram_benchmark.cjs
```

#### 3. deploy_sepolia.cjs — Scenario 2

```
Purpose:    Deploy contracts to Sepolia testnet
             Measure REAL gas consumption (not estimates)
Location:   LOCAL
Output:     results/sepolia/sepolia_gas_report.json
            deployment_sepolia.json
Prereq:     Sepolia ETH from https://www.sepoliafaucet.io/
Setup:      Create .env with SEPOLIA_RPC_URL and DEPLOYER_PRIVATE_KEY
Run:        node scripts/deploy_sepolia.cjs
```

---

### Each VM (6 scripts)

These run on **each VM** - requires Docker + local chains:

#### 4. azure_vm_setup.sh — Setup

```
Purpose:    Install Docker, Node.js, build tools on fresh VM
Location:   EACH VM
Run:        bash scripts/azure_vm_setup.sh
Note:       Only needed once per VM initially
```

#### 5. docker-compose-10vm.yml — Start Chains

```
Purpose:    Start 10 local Ethereum chains (20 containers)
Location:   EACH VM
Run:        cd docker && cp .env.vm1 .env && docker compose up -d
Ports:      8545-8564 (chain RPC endpoints)
```

#### 6. deploy_contracts_v2.cjs — Deploy Local

```
Purpose:    Deploy ReputationRegistry, ClusterManager, AuditContractV2
             to local chains on THIS VM
Location:   EACH VM (deploy separately per VM)
Run:        VM_ID=1 node scripts/deploy_contracts_v2.cjs
Output:     deployment_v2.json (per VM)
Note:       Each VM has its own deployment_v2.json
```

#### 7. real_workload_experiment.cjs — TN2

```
Purpose:    Measure O(k) → O(√k) workload reduction
             Compare original vs v2 audit proofs
Location:   EACH VM (run after deploy_contracts_v2.cjs)
Run:        node scripts/real_workload_experiment.cjs
Output:     results/workload/tn2_workload.json
            results/workload/tn2_workload.csv
```

#### 8. real_latency_experiment.cjs — TN3

```
Purpose:    Measure end-to-end audit latency
             Compare serial vs aggregated submission
Location:   EACH VM (run after deploy_contracts_v2.cjs)
Run:        node scripts/real_latency_experiment.cjs
Output:     results/latency/tn3_latency.json
            results/latency/tn3_latency.csv
```

#### 9. network_latency_experiment.sh — Scenario 1

```
Purpose:    Inject tc/netem latency (0, 50, 150, 300ms)
             Measure impact on consensus + proof generation
Location:   EACH VM (Linux with iproute2)
Run:        sudo bash scripts/network_latency_experiment.sh
Output:     results/network_latency/
Prereq:     Docker containers running, --privileged mode
```

---

## Bug Fixes (B1-B4)

### B1: Groth16 Constraint Fix ⚠️

**Issue:** Paper claims ~40K constraints, reality ~20M (500x off)

**Files:** `circuits/circom/zkcross_psi.circom`

**Fix:** Real constraint counting via snarkjs:

```bash
# Run on LOCAL
node scripts/groth16_ram_benchmark.cjs
```

**Results show realistic RAM/time:**

```
 Circuit | Constraints | Proving RAM | Verif RAM
---------|-------------|-------------|----------
 micro   |      0.5M  |      1.5 GB |   0.1 GB
 large   |     16.0M  |     48.0 GB |   0.1 GB
```

### B2: VRF Shuffling + Data Availability

**File:** `contracts/audit_chain/ClusterManager.sol`

| Line    | Function               | Description                         |
| ------- | ---------------------- | ----------------------------------- |
| 342-393 | `reshuffleClusters()`  | Fisher-Yates VRF shuffle per epoch  |
| 413-446 | `fileDAChallenge()`    | Fraud proofs for missing chain data |
| 454+    | `resolveDAChallenge()` | Challenge resolution + CH penalty   |

**Run DA challenge:**

```bash
# After Docker is running on VM
# Any node can file challenge if CH withholds chain data
```

### B3: Slashing + Arbitration

**File:** `contracts/audit_chain/ReputationRegistry.sol`

| Line    | Function          | Description                         |
| ------- | ----------------- | ----------------------------------- |
| 301-328 | Reputation update | Non-linear 5x penalty when C=0      |
| 318-324 | Slashing          | 10% stake slashed per violation     |
| 462-480 | `fileAppeal()`    | Committer appeals wrong CH judgment |
| 493-523 | `resolveAppeal()` | On-chain arbitration                |

**Proof of fix:**

```bash
# Run on LOCAL - shows attacker reputation drops to 0.01
python scripts/mfpop_simulation.py
```

### B4: Accuracy Recovery Graph

**File:** `scripts/mfpop_simulation.py`

```bash
# Generates: results/mfpop_reputation_recovery.png
# Shows accuracy recovery from round 1-50
python scripts/mfpop_simulation.py
```

---

## Results Output Locations

| Experiment           | Location                                                    |
| -------------------- | ----------------------------------------------------------- |
| TN1 + Scenario 4     | `results/mfpop_*.png`, `results/mfpop_simulation_data.json` |
| Scenario 2 (Sepolia) | `results/sepolia/sepolia_gas_report.json`                   |
| Scenario 3 (RAM)     | `results/ram_benchmark/groth16_ram_report.json`             |
| TN2 (Workload)       | `results/workload/tn2_workload.csv`                         |
| TN3 (Latency)        | `results/latency/tn3_latency.csv`                           |
| Scenario 1 (Network) | `results/network_latency/`                                  |

---

## Copy Results to Local

```bash
# From local machine
scp -r -i VM_key.pem azureuser@<VM1_IP>:~/zkCross/results/ ./results_vm1/
scp -r -i VM_key.pem azureuser@<VM2_IP>:~/zkCross/results/ ./results_vm2/
# ... repeat for all VMs
```

---

## Troubleshooting

### Docker Permission Denied

```bash
exit  # Relogin
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

### Sepolia Deployment Failed

```bash
# Check balance
curl -s -X POST -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0x...", "latest"],"id":1}' \
  https://rpc.sepolia.org

# Get more ETH: https://www.sepoliafaucet.io/
```

---

## Port Mapping (Per VM)

```
Chain 1:  8545 (n1), 8546 (n2)   → chainId 101
Chain 2:  8547 (n1), 8548 (n2)   → chainId 102
Chain 3:  8549 (n1), 8550 (n2)   → chainId 103
Chain 4:  8551 (n1), 8552 (n2)   → chainId 104
Chain 5:  8553 (n1), 8554 (n2)   → chainId 105
Chain 6:  8555 (n1), 8556 (n2)   → chainId 106
Chain 7:  8557 (n1), 8558 (n2)   → chainId 107
Chain 8:  8559 (n1), 8560 (n2)   → chainId 108
Chain 9:  8561 (n1), 8562 (n2)   → chainId 109
Chain 10: 8563 (n1), 8564 (n2)   → chainId 110
```

---

## Project Structure

```
zkCross/
├── scripts/
│   ├── azure_vm_setup.sh          # VM: Setup Docker/Node.js
│   ├── deploy_contracts_v2.cjs     # VM: Deploy to local chains
│   ├── deploy_sepolia.cjs         # LOCAL: Deploy to Sepolia
│   ├── real_workload_experiment.cjs  # VM: TN2 workload
│   ├── real_latency_experiment.cjs   # VM: TN3 latency
│   ├── network_latency_experiment.sh # VM: Scenario 1 (tc/netem)
│   ├── mfpop_simulation.py        # LOCAL: TN1 + Scenario 4
│   ├── groth16_ram_benchmark.cjs  # LOCAL: Scenario 3
│   └── run_all_vms_experiments.sh # Run on all VMs
├── docker/
│   ├── docker-compose-10vm.yml    # VM: 10 local chains
│   └── .env.vm1 - .env.vm10      # VM: Per-VM config
├── contracts/
│   ├── audit_chain/
│   │   ├── AuditContractV2.sol   # Enhanced Protocol Ψ
│   │   ├── ClusterManager.sol     # VRF + DA challenge
│   │   └── ReputationRegistry.sol # Slashing + arbitration
│   └── ordinary_chain/
├── circuits/
│   └── circom/
│       └── zkcross_psi.circom    # Groth16 circuit
└── results/                       # All experiment outputs
    ├── mfpop_*.png                # TN1 + B4
    ├── sepolia/                   # Scenario 2
    ├── ram_benchmark/             # Scenario 3
    ├── workload/                  # TN2
    ├── latency/                   # TN3
    └── network_latency/           # Scenario 1
```

bash scripts/deploy_to_10vm.sh
run_all_vms_experiments.sh
