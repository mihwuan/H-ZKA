#!/bin/bash
# =====================================================================
# zkCross v2 — Azure VM Experiments (10 Chains × 2 Nodes)
# =====================================================================
#
# Chạy sau khi đã:
#   1. SSH vào VM
#   2. Docker containers đã chạy: docker compose up -d
#
# Cách dùng:
#   cd ~/zkCross
#   bash scripts/run_azure_experiments.sh
#
# =====================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
RESULTS_DIR="$PROJECT_DIR/results"

mkdir -p "$RESULTS_DIR"

# Detect VM_ID from environment or .env file
VM_ID="${VM_ID:-1}"
if [ -f "$PROJECT_DIR/docker/.env" ]; then
    VM_ID=$(grep "^VM_ID=" "$PROJECT_DIR/docker/.env" | cut -d'=' -f2)
fi

echo "========================================================"
echo "  zkCross v2 — Azure VM Experiments (VM${VM_ID})"
echo "  10 chains × 2 nodes per VM"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
echo ""
echo "  VM: $(uname -n)"
echo "  CPU: $(nproc) cores"
echo "  RAM: $(free -h | awk '/Mem:/{print $2}')"
echo "  Swap: $(free -h | awk '/Swap:/{print $2}')"
echo ""

cd "$PROJECT_DIR"

# ==========================================================
# PHASE 1: Check Docker Status
# ==========================================================
echo "========================================================"
echo "  PHASE 1: Docker Blockchain Status"
echo "========================================================"

CONTAINER_COUNT=$(docker ps -q | wc -l)
echo ""
echo "  Running containers: $CONTAINER_COUNT (expected: 20)"

if [ "$CONTAINER_COUNT" -lt 10 ]; then
    echo ""
    echo "  ⚠ WARNING: Less than 10 containers running!"
    echo "  Start Docker with: cd docker && docker compose up -d"
    echo ""
fi

# Check RPC connectivity for all 10 chains
echo ""
echo "  Checking RPC connectivity..."
for i in $(seq 1 10); do
    PORT=$((8545 + (i - 1) * 2))
    if curl -sf -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "http://localhost:$PORT" > /dev/null 2>&1; then
        echo "    Chain $i (port $PORT): ✓"
    else
        echo "    Chain $i (port $PORT): ✗"
    fi
done

# ==========================================================
# PHASE 2: Deploy Contracts
# ==========================================================
echo ""
echo "========================================================"
echo "  PHASE 2: Deploy Contracts"
echo "========================================================"

# Check if deployment already exists
if [ -f "$PROJECT_DIR/deployment_v2.json" ]; then
    echo ""
    echo "  ⚠ deployment_v2.json already exists"
    echo "  Skipping deployment (delete to re-deploy)"
else
    echo ""
    echo "  Deploying contracts..."
    VM_ID=$VM_ID node "$PROJECT_DIR/scripts/deploy_contracts_v2.cjs"
fi

# ==========================================================
# PHASE 3: Run Experiments
# ==========================================================
echo ""
echo "========================================================"
echo "  PHASE 3: Experiments"
echo "========================================================"

echo ""
echo "[3.1] TN2: Workload Reduction..."
node "$PROJECT_DIR/scripts/real_workload_experiment.cjs" 2>&1 | tail -20
echo "  ✓ Saved: results/workload/"

echo ""
echo "[3.2] TN3: Latency & Throughput..."
node "$PROJECT_DIR/scripts/real_latency_experiment.cjs" 2>&1 | tail -20
echo "  ✓ Saved: results/latency/"

echo ""
echo "[3.3] TN4: Gas Consumption..."
node "$PROJECT_DIR/test/gas_consumption_v2.cjs" 2>&1 | tail -20
echo "  ✓ Saved: results/gas/"

# ==========================================================
# PHASE 4: Results Summary
# ==========================================================
echo ""
echo "========================================================"
echo "  PHASE 4: Results Summary"
echo "========================================================"

# Collect all results into one summary
cat > "$RESULTS_DIR/experiment_summary.json" << EOF
{
  "vm": {
    "id": ${VM_ID},
    "type": "Standard_E4s_v3",
    "vcpus": $(nproc),
    "ram_gb": $(free -g | awk '/Mem:/{print $2}'),
    "chain_count": 10,
    "nodes_per_chain": 2,
    "total_nodes": 20,
    "date": "$(date -Iseconds)"
  },
  "experiments": {
    "tn2_workload": "results/workload/",
    "tn3_latency": "results/latency/",
    "tn4_gas": "results/gas/"
  }
}
EOF

echo ""
echo "  Results saved to: $RESULTS_DIR/"
echo ""
echo "  Files:"
find "$RESULTS_DIR" -name "*.json" -o -name "*.csv" 2>/dev/null | head -20

# ==========================================================
# Summary
# ==========================================================
echo ""
echo "========================================================"
echo "  ALL EXPERIMENTS COMPLETE!"
echo "========================================================"
echo ""
echo "  Copy results to local machine:"
echo "    scp -r -i VM_key.pem azureuser@<IP>:~/zkCross/results/ ./results_vm${VM_ID}/"
echo ""
echo "========================================================"
