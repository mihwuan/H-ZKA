#!/bin/bash
# =====================================================================
# zkCross v2 — Run Experiments on ALL 10 VMs (200 Nodes)
# =====================================================================
#
# This script orchestrates experiments across ALL 10 Azure VMs.
# Each VM runs 10 chains × 2 nodes = 20 nodes.
# Total: 10 VMs × 20 nodes = 200 nodes.
#
# Usage:
#   From LOCAL machine (has SSH access to all VMs):
#   bash scripts/run_all_vms_experiments.sh
#
# =====================================================================

set -eo pipefail


# Ghi log toàn bộ output ra file (vừa hiện ra màn hình, vừa lưu file)
LOG_FILE="$(dirname "$0")/../run_all_vms_experiments.log"
exec > >(tee -a "$LOG_FILE") 2>&1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
VM1_KEY="/home/mihwuan/Project/VM_key.pem"
VM2_KEY="/home/mihwuan/Project/VM2_key.pem"
RESULTS_DIR="$PROJECT_DIR/results/all_vms"

# VM Configuration - 10 Azure VMs
declare -A VM_IPS
VM_IPS[1]="20.243.120.13"   # VM1
VM_IPS[2]="20.92.252.112"   # VM2
VM_IPS[3]="20.116.219.110"  # VM3
VM_IPS[4]="20.67.233.108"   # VM4
VM_IPS[5]="20.197.48.113"   # VM5
VM_IPS[6]="102.37.222.0"    # VM6
VM_IPS[7]="51.107.9.211"    # VM7
VM_IPS[8]="74.163.241.42"   # VM8
VM_IPS[9]="40.82.159.250"   # VM9
VM_IPS[10]="20.66.73.64"    # VM10

VM_USER="azureuser"

# Get SSH key for a specific VM (VM1 uses VM_key.pem, VMs 2-10 use VM2_key.pem)
get_vm_key() {
    local vm_num=$1
    if [ "$vm_num" -eq 1 ]; then
        echo "$VM1_KEY"
    else
        echo "$VM2_KEY"
    fi
}

# Total VMs to use (can change to 2 for testing)
NUM_VMS="${NUM_VMS:-10}"

echo "========================================================"
echo "  zkCross v2 — Cross-VM Experiments"
echo "  Total: ${NUM_VMS} VMs × 10 chains × 2 nodes = $((NUM_VMS * 20)) nodes"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"
echo ""

mkdir -p "$RESULTS_DIR"

# =====================================================================
# Step 1: Check SSH connectivity to all VMs
# =====================================================================
echo "[Step 1] Checking SSH connectivity to all VMs..."

FAILED_VMS=0
for i in $(seq 1 $NUM_VMS); do
    vm_ip="${VM_IPS[$i]}"
    key=$(get_vm_key $i)
    if ssh -i "$key" -o ConnectTimeout=5 -o BatchMode=yes "$VM_USER@$vm_ip" "echo ok" > /dev/null 2>&1; then
        echo "  VM #$i ($vm_ip): ✓ Connected"
    else
        echo "  VM #$i ($vm_ip): ✗ Failed"
        FAILED_VMS=$((FAILED_VMS + 1))
    fi
done

if [ $FAILED_VMS -gt 0 ]; then
    echo ""
    echo "⚠ WARNING: $FAILED_VMS VMs unreachable. Continue anyway? (y/n)"
    read -r answer
    if [ "$answer" != "y" ]; then
        echo "Aborted."
        exit 1
    fi
fi

# =====================================================================
# Step 2: Check Docker status on all VMs
# =====================================================================
echo ""
echo "[Step 2] Checking Docker status on all VMs..."

for i in $(seq 1 $NUM_VMS); do
    vm_ip="${VM_IPS[$i]}"
    key=$(get_vm_key $i)
    echo -n "  VM #$i ($vm_ip): "

    CONTAINER_COUNT=$(ssh -i "$key" "$VM_USER@$vm_ip" "docker ps -q 2>/dev/null | wc -l" 2>/dev/null || echo "0")

    if [ "$CONTAINER_COUNT" -ge 20 ]; then
        echo "✓ $CONTAINER_COUNT containers running"
    elif [ "$CONTAINER_COUNT" -gt 0 ]; then
        echo "⚠ Only $CONTAINER_COUNT containers (expected 20)"
    else
        echo "✗ No containers - need to start Docker"
        echo "    Run on VM #$i: cd ~/zkCross/docker && docker compose -f docker-compose-10vm.yml up -d"
    fi
done

# =====================================================================
# Step 3: Deploy contracts on all VMs (if needed)
# =====================================================================
echo ""
echo "[Step 3] Checking contract deployment on all VMs..."

for i in $(seq 1 $NUM_VMS); do
    vm_ip="${VM_IPS[$i]}"
    key=$(get_vm_key $i)
    echo -n "  VM #$i ($vm_ip): "

    HAS_DEPLOYMENT=$(ssh -i "$key" "$VM_USER@$vm_ip" "[ -f ~/zkCross/deployment_v2.json ] && echo yes || echo no" 2>/dev/null)

    if [ "$HAS_DEPLOYMENT" = "yes" ]; then
        echo "✓ deployment_v2.json exists"
    else
        echo "⚠ No deployment - will deploy contracts"
        ssh -i "$key" "$VM_USER@$vm_ip" \
            "cd ~/zkCross && VM_ID=$i node scripts/deploy_contracts_v2.cjs" &
    fi
done



# =====================================================================
# Step 4: Run experiments on all VMs in parallel
# =====================================================================
echo ""
echo "[Step 4] Running experiments on all VMs in parallel..."
echo "  This will take several minutes..."

PIDS=()
for i in $(seq 1 $NUM_VMS); do
    vm_ip="${VM_IPS[$i]}"
    key=$(get_vm_key $i)

    echo "  Starting experiments on VM #$i ($vm_ip)..."

    # Run experiments in background
    ssh -i "$key" "$VM_USER@$vm_ip" \
        "cd ~/zkCross && bash scripts/run_azure_experiments.sh" > "$RESULTS_DIR/vm${i}_experiments.log" 2>&1 &

    PIDS+=($!)
done

# =====================================================================
# Step 5: Monitor progress
# =====================================================================
echo ""
echo "[Step 5] Monitoring experiment progress..."

COMPLETED=0
while [ $COMPLETED -lt $NUM_VMS ]; do
    COMPLETED=0
    for i in $(seq 1 $NUM_VMS); do
        if ! kill -0 ${PIDS[$((i-1))]} 2>/dev/null; then
            COMPLETED=$((COMPLETED + 1))
        fi
    done
    echo "  Completed: $COMPLETED / $NUM_VMS"
    sleep 10
done


echo ""
echo "  All VMs completed experiments."

# =====================================================================
# Step 6: Collect results from all VMs
# =====================================================================
echo ""
echo "[Step 6] Collecting results from all VMs..."

for i in $(seq 1 $NUM_VMS); do
    vm_ip="${VM_IPS[$i]}"
    key=$(get_vm_key $i)
    echo "  VM #$i ($vm_ip): "

    # Copy results
    mkdir -p "$RESULTS_DIR/vm${i}"
    scp -i "$key" -q "$VM_USER@$vm_ip:~/zkCross/results/"* "$RESULTS_DIR/vm${i}/" 2>/dev/null || true

    echo "    ✓ Results copied"
done

# =====================================================================
# Step 7: Aggregate results
# =====================================================================
echo ""
echo "[Step 7] Aggregating results..."

# Create summary
cat > "$RESULTS_DIR/summary.json" << EOF
{
  "experiment": "zkCross v2 Cross-VM Experiments",
  "date": "$(date -Iseconds)",
  "total_vms": $NUM_VMS,
  "total_chains": $((NUM_VMS * 10)),
  "total_nodes": $((NUM_VMS * 20)),
  "results_per_vm": {
$(for i in $(seq 1 $NUM_VMS); do
    echo "    \"vm${i}\": \"vm${i}/\""
done
)
  }
}
EOF

echo ""
echo "  Summary saved to: $RESULTS_DIR/summary.json"

# =====================================================================
# Final Summary
# =====================================================================
echo ""
echo "========================================================"
echo "  ALL CROSS-VM EXPERIMENTS COMPLETE!"
echo "========================================================"
echo ""
echo "  Results saved to: $RESULTS_DIR/"
echo ""
echo "  VM Results:"
for i in $(seq 1 $NUM_VMS); do
    echo "    VM #$i: $RESULTS_DIR/vm${i}/"
done
echo ""
echo "  Summary: $RESULTS_DIR/summary.json"
echo ""
echo "========================================================"
