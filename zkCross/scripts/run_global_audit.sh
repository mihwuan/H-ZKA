#!/bin/bash
# =====================================================================
# zkCross - Run Global Audit Experiment on VM1
# =====================================================================
#
# This script is launched from the local machine. VM1 is used as the
# global audit chain RPC endpoint. It deploys one global audit stack,
# registers all 100 chain IDs, runs global audit rounds, and copies the
# result files back to local results/global_audit/.
#
# Usage:
#   bash scripts/run_global_audit.sh
#   GLOBAL_AUDIT_ROUNDS=10 bash scripts/run_global_audit.sh
# =====================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."

VM1_IP="${VM1_IP:-20.243.120.13}"
VM1_KEY="/home/mihwuan/Project/VM_key.pem"
VM_USER="${VM_USER:-azureuser}"
GLOBAL_AUDIT_ROUNDS="${GLOBAL_AUDIT_ROUNDS:-5}"
RESULTS_DIR="$PROJECT_DIR/results/global_audit"

echo "========================================================"
echo "  zkCross - Global Audit Runner"
echo "  VM1: $VM1_IP"
echo "  Rounds: $GLOBAL_AUDIT_ROUNDS"
echo "========================================================"

mkdir -p "$RESULTS_DIR"

echo ""
echo "[1/5] Checking VM1 SSH and audit RPC..."
ssh -i "$VM1_KEY" -o ConnectTimeout=10 -o BatchMode=yes "$VM_USER@$VM1_IP" "echo ok" >/dev/null
ssh -i "$VM1_KEY" "$VM_USER@$VM1_IP" \
  "curl -sf -X POST -H 'Content-Type: application/json' --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}' http://localhost:8545 >/dev/null"
echo "  ✓ VM1 reachable and audit RPC is healthy"

echo ""
echo "[2/5] Syncing global audit scripts to VM1..."
scp -i "$VM1_KEY" -q "$SCRIPT_DIR/compile_global_compatible.cjs" "$VM_USER@$VM1_IP:~/zkCross/scripts/"
scp -i "$VM1_KEY" -q "$SCRIPT_DIR/deploy_global_audit.cjs" "$VM_USER@$VM1_IP:~/zkCross/scripts/"
scp -i "$VM1_KEY" -q "$SCRIPT_DIR/global_audit_experiment.cjs" "$VM_USER@$VM1_IP:~/zkCross/scripts/"
echo "  ✓ Scripts synced"

echo ""
echo "[3/5] Deploying global audit stack on VM1..."
echo "  Compiling global audit contracts with solc evmVersion=paris..."

ssh -i "$VM1_KEY" "$VM_USER@$VM1_IP" \
  "bash -lc 'source ~/.nvm/nvm.sh && cd ~/zkCross && node scripts/compile_global_compatible.cjs >/tmp/zkcross_global_compile.log 2>&1 || { cat /tmp/zkcross_global_compile.log; exit 1; } && tail -10 /tmp/zkcross_global_compile.log'"

ssh -i "$VM1_KEY" "$VM_USER@$VM1_IP" \
  "bash -lc 'source ~/.nvm/nvm.sh && cd ~/zkCross && GLOBAL_AUDIT_RPC=http://localhost:8545 node scripts/deploy_global_audit.cjs'"

echo ""
echo "[4/5] Running global audit experiment..."
ssh -i "$VM1_KEY" "$VM_USER@$VM1_IP" \
  "bash -lc 'source ~/.nvm/nvm.sh && cd ~/zkCross && GLOBAL_AUDIT_RPC=http://localhost:8545 GLOBAL_AUDIT_ROUNDS=$GLOBAL_AUDIT_ROUNDS node scripts/global_audit_experiment.cjs'"
  
echo ""
echo "[5/5] Copying global audit results back to local..."
scp -i "$VM1_KEY" -q "$VM_USER@$VM1_IP:~/zkCross/deployment_global_audit.json" "$RESULTS_DIR/" || true
scp -i "$VM1_KEY" -q "$VM_USER@$VM1_IP:~/zkCross/results/global_audit/"* "$RESULTS_DIR/" || true
echo "  ✓ Results copied to $RESULTS_DIR"

echo ""
echo "========================================================"
echo "  GLOBAL AUDIT DONE"
echo "========================================================"
echo "  JSON: $RESULTS_DIR/global_audit_report.json"
echo "  CSV:  $RESULTS_DIR/global_audit_rounds.csv"
echo "========================================================"
