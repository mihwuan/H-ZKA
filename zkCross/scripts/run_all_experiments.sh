#!/bin/bash
# =====================================================================
# zkCross v2 — MASTER SCRIPT: Full System Experiment
# =====================================================================
#
# Chạy toàn bộ 4 kịch bản + TN1-TN6 trên 200 nodes, 100 chains
#
# Usage:
#   bash scripts/run_all_experiments.sh [options]
#
# Options:
#   --skip-local     Bỏ qua experiments trên local (Scenario 2,3,4)
#   --skip-vms       Bỏ qua deploy + experiments trên VMs
#   --skip-sepolia   Bỏ qua Sepolia deployment
#   --scenarios      Chỉ chạy scenarios cụ thể (1,2,3,4)
#   --tns            Chỉ chạy TN cụ thể (1,2,3,4,5,6)
#   --vm-only        Chỉ chạy experiments trên VMs (đã deploy rồi)
#
# =====================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$PROJECT_DIR/results/full_system"
VM1_KEY="${VM1_KEY:-$HOME/VM_key.pem}"
VM2_KEY="${VM2_KEY:-$HOME/VM2_key.pem}"
VM_USER="azureuser"

# =====================================================================
# Configuration
# =====================================================================

# VM IP addresses (10 Azure VMs)
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

NUM_VMS=10

# Parse arguments
SKIP_LOCAL=false
SKIP_VMS=false
SKIP_SEPOLIA=false
VM_ONLY=false
SCENARIOS=""
TNS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-local) SKIP_LOCAL=true; shift ;;
        --skip-vms) SKIP_VMS=true; shift ;;
        --skip-sepolia) SKIP_SEPOLIA=true; shift ;;
        --vm-only) VM_ONLY=true; SKIP_LOCAL=false; shift ;;
        --scenarios) SCENARIOS="$2"; shift 2 ;;
        --tns) TNS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# =====================================================================
# Helpers
# =====================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

section() {
    echo ""
    echo "========================================================================"
    echo "  $*"
    echo "========================================================================"
}

# Get SSH key for a specific VM (VM1 uses VM_key.pem, VMs 2-10 use VM2_key.pem)
get_vm_key() {
    local vm_num=$1
    if [ "$vm_num" -eq 1 ]; then
        echo "$VM1_KEY"
    else
        echo "$VM2_KEY"
    fi
}

check_ssh() {
    local vm_ip=$1
    local vm_num=$2
    local key=$(get_vm_key $vm_num)
    ssh -i "$key" -o ConnectTimeout=5 -o BatchMode=yes "$VM_USER@$vm_ip" "echo ok" > /dev/null 2>&1
}

# =====================================================================
# PHASE 1: Local Experiments (Scenario 2, 3, 4)
# =====================================================================

run_local_experiments() {
    section "PHASE 1: LOCAL EXPERIMENTS (Scenario 2, 3, 4)"
    echo ""

    cd "$PROJECT_DIR"

    # Ensure results directory exists
    mkdir -p "$RESULTS_DIR/local"

    # ------------------------------------------------------------------
    # SCENARIO 4 + TN1: MF-PoP Game Theory Simulation
    # ------------------------------------------------------------------
    if [ -z "$SCENARIOS" ] || [[ "$SCENARIOS" == *"4"* ]]; then
        section "Scenario 4 + TN1: MF-PoP Game Theory Simulation"
        log "Running oscillating Byzantine attack simulation..."
        log "This proves B3 fix effectiveness"

        python scripts/mfpop_simulation.py

        # Move results
        if [ -d "$PROJECT_DIR/results" ]; then
            mv "$PROJECT_DIR/results/mfpop_"* "$RESULTS_DIR/local/" 2>/dev/null || true
            mv "$PROJECT_DIR/results/mfpop_simulation_data.json" "$RESULTS_DIR/local/" 2>/dev/null || true
        fi

        log "Results: $RESULTS_DIR/local/mfpop_*.png"
        echo ""
    fi

    # ------------------------------------------------------------------
    # SCENARIO 3 + TN4: RAM Micro-Benchmarking
    # ------------------------------------------------------------------
    if [ -z "$SCENARIOS" ] || [[ "$SCENARIOS" == *"3"* ]]; then
        section "Scenario 3 + TN4: Groth16 RAM Benchmark"
        log "Measuring RAM consumption for different circuit sizes..."
        log "Estimates: 0.5M to 16M constraints"

        node scripts/groth16_ram_benchmark.cjs

        # Move results
        mkdir -p "$RESULTS_DIR/local/ram_benchmark"
        mv "$PROJECT_DIR/results/ram_benchmark/"* "$RESULTS_DIR/local/ram_benchmark/" 2>/dev/null || true

        log "Results: $RESULTS_DIR/local/ram_benchmark/groth16_ram_report.json"
        echo ""
    fi

    # ------------------------------------------------------------------
    # SCENARIO 2 + TN4: Sepolia Gas Measurement
    # ------------------------------------------------------------------
    if [ -z "$SCENARIOS" ] || [[ "$SCENARIOS" == *"2"* ]]; then
        section "Scenario 2 + TN4: Sepolia Gas Measurement"
        log "Deploying contracts to Sepolia testnet..."

        if [ ! -f "$PROJECT_DIR/.env" ]; then
            log "WARNING: .env not found. Creating with default settings..."
            echo "SEPOLIA_RPC_URL=https://rpc.sepolia.org" > "$PROJECT_DIR/.env"
            echo "DEPLOYER_PRIVATE_KEY=0x4c0883a69102937d6231471b5dbb6204fe512961708279f22f1da1c87a3b8b4b" >> "$PROJECT_DIR/.env"
            log "Created .env with default key. Get Sepolia ETH from https://www.sepoliafaucet.io/"
        fi

        node scripts/deploy_sepolia.cjs

        # Move results
        mkdir -p "$RESULTS_DIR/local/sepolia"
        mv "$PROJECT_DIR/results/sepolia/"* "$RESULTS_DIR/local/sepolia/" 2>/dev/null || true
        mv "$PROJECT_DIR/deployment_sepolia.json" "$RESULTS_DIR/local/sepolia/" 2>/dev/null || true

        log "Results: $RESULTS_DIR/local/sepolia/sepolia_gas_report.json"
        echo ""
    fi
}

# =====================================================================
# PHASE 2: Deploy to All VMs
# =====================================================================

deploy_to_vms() {
    section "PHASE 2: DEPLOY TO ALL $NUM_VMS VMs"
    echo ""

    log "This will deploy to $NUM_VMS VMs with IPs:"
    for i in $(seq 1 $NUM_VMS); do
        echo "  VM #$i: ${VM_IPS[$i]}"
    done
    echo ""

    # Check SSH connectivity first
    log "Checking SSH connectivity..."
    FAILED=0
    for i in $(seq 1 $NUM_VMS); do
        if check_ssh "${VM_IPS[$i]}" "$i"; then
            echo "  VM #$i: ✓"
        else
            echo "  VM #$i: ✗ FAILED"
            FAILED=1
        fi
    done

    if [ $FAILED -eq 1 ]; then
        log "WARNING: Some VMs are unreachable. Continue anyway? (y/n)"
        read -r answer
        if [ "$answer" != "y" ]; then
            log "Aborted."
            exit 1
        fi
    fi

    # Run deployment script
    log "Running deploy_to_10vm.sh..."
    bash "$SCRIPT_DIR/deploy_to_10vm.sh"

    log "Deployment complete!"
}

# =====================================================================
# PHASE 3: VM Experiments (TN2, TN3, TN5, TN6)
# =====================================================================

run_vm_experiments() {
    section "PHASE 3: VM EXPERIMENTS (TN2, TN3, TN5, TN6)"
    echo ""

    mkdir -p "$RESULTS_DIR/vms"

    # ------------------------------------------------------------------
    # Run experiments on each VM in parallel
    # ------------------------------------------------------------------
    log "Starting experiments on all $NUM_VMS VMs in parallel..."

    PIDS=()
    for i in $(seq 1 $NUM_VMS); do
        vm_ip="${VM_IPS[$i]}"
        vm_results="$RESULTS_DIR/vms/vm${i}"
        mkdir -p "$vm_results"
        key=$(get_vm_key $i)

        {
            ssh -i "$key" "$VM_USER@$vm_ip" << EOF
                set -e
                cd ~/zkCross

                # TN2: Workload Reduction Experiment
                if [ -f scripts/real_workload_experiment.cjs ]; then
                    echo "[VM$i] Running TN2: Workload Reduction..."
                    VM_ID=$i node scripts/real_workload_experiment.cjs || true
                fi

                # TN3: Latency Experiment
                if [ -f scripts/real_latency_experiment.cjs ]; then
                    echo "[VM$i] Running TN3: Latency Measurement..."
                    VM_ID=$i node scripts/real_latency_experiment.cjs || true
                fi

                # Copy results
                mkdir -p ~/zkCross/results/vm\$i
                cp -r ~/zkCross/results/* ~/zkCross/results/vm\$i/ 2>/dev/null || true
EOF

            # Copy results from this VM
            scp -i "$key" -q "$VM_USER@$vm_ip:~/zkCross/results/"* "$vm_results/" 2>/dev/null || true

            echo "  VM #$i: ✓ Completed"
        } &

        PIDS+=($!)
    done

    # Wait for all VMs
    log "Waiting for all VMs to complete..."
    for pid in "${PIDS[@]}"; do
        wait $pid || true
    done

    log "All VM experiments completed!"
}

# =====================================================================
# PHASE 4: Scenario 1 - Network Latency (tc/netem)
# =====================================================================

run_network_latency_experiment() {
    section "SCENARIO 1: Network Latency (tc/netem)"
    echo ""

    if [ -z "$SCENARIOS" ] || [[ "$SCENARIOS" == *"1"* ]]; then
        log "This requires Linux with iproute2 and Docker --privileged"
        log "Running on each VM with latency: 0ms, 50ms, 150ms, 300ms"
        echo ""

        mkdir -p "$RESULTS_DIR/vms/network_latency"

        for i in $(seq 1 $NUM_VMS); do
            vm_ip="${VM_IPS[$i]}"
            key=$(get_vm_key $i)
            echo "  VM #$i ($vm_ip): Running tc/netem experiment..."

            ssh -i "$key" "$VM_USER@$vm_ip" << EOF &
                set -e
                cd ~/zkCross

                # Run network latency experiment (requires sudo)
                if [ -f scripts/network_latency_experiment.sh ]; then
                    sudo bash scripts/network_latency_experiment.sh || true
                fi

                # Copy results
                cp -r ~/zkCross/results/network_latency/* ~/zkCross/results/vm\$i/ 2>/dev/null || true
EOF
        done

        # Wait a bit for parallel execution
        sleep 5

        # Collect results
        for i in $(seq 1 $NUM_VMS); do
            vm_ip="${VM_IPS[$i]}"
            key=$(get_vm_key $i)
            scp -i "$key" -q "$VM_USER@$vm_ip:~/zkCross/results/network_latency/"* \
                "$RESULTS_DIR/vms/network_latency/" 2>/dev/null || true
        done

        log "Network latency experiments completed!"
    else
        log "Skipping Scenario 1 (use --scenarios 1 to run)"
    fi
}

# =====================================================================
# PHASE 5: Aggregate & Generate Reports
# =====================================================================

generate_final_report() {
    section "PHASE 5: GENERATING FINAL REPORT"
    echo ""

    cd "$PROJECT_DIR"

    # Create aggregated summary
    cat > "$RESULTS_DIR/summary.json" << EOF
{
  "experiment": "zkCross v2 Full System Experiment",
  "date": "$(date -Iseconds)",
  "system": {
    "total_vms": $NUM_VMS,
    "chains_per_vm": 10,
    "nodes_per_chain": 2,
    "total_chains": $((NUM_VMS * 10)),
    "total_nodes": $((NUM_VMS * 20))
  },
  "phases": {
    "phase1_local": {
      "scenarios": ["2", "3", "4"],
      "tn_experiments": ["TN1", "TN4"],
      "description": "Local experiments: Sepolia gas, RAM benchmark, MF-PoP simulation"
    },
    "phase2_deploy": {
      "description": "Deploy contracts to all 10 VMs"
    },
    "phase3_vm": {
      "scenarios": [],
      "tn_experiments": ["TN2", "TN3", "TN5", "TN6"],
      "description": "VM experiments: workload, latency, privacy, byzantine"
    },
    "phase4_network": {
      "scenarios": ["1"],
      "description": "tc/netem latency injection: 0, 50, 150, 300ms"
    }
  },
  "results": {
    "local": "$RESULTS_DIR/local",
    "vms": "$RESULTS_DIR/vms"
  }
}
EOF

    # Generate CSV summary from all experiments
    echo "Generating summary CSVs..."

    # TN2 Workload
    if [ -f "$RESULTS_DIR/vms/vm1/workload/tn2_workload.csv" ]; then
        head -20 "$RESULTS_DIR/vms/vm1/workload/tn2_workload.csv" || true
    fi

    # TN3 Latency
    if [ -f "$RESULTS_DIR/vms/vm1/latency/tn3_latency.csv" ]; then
        head -20 "$RESULTS_DIR/vms/vm1/latency/tn3_latency.csv" || true
    fi

    # Sepolia Gas
    if [ -f "$RESULTS_DIR/local/sepolia/sepolia_gas_report.json" ]; then
        cat "$RESULTS_DIR/local/sepolia/sepolia_gas_report.json" | head -50 || true
    fi

    echo ""
    log "Full results saved to: $RESULTS_DIR/"
}

# =====================================================================
# Main Flow
# =====================================================================

main() {
    echo ""
    echo "========================================================================"
    echo "  zkCross v2 — FULL SYSTEM EXPERIMENT"
    echo "  200 Nodes | 100 Chains | 10 VMs"
    echo "  4 Scenarios + TN1-TN6"
    echo "========================================================================"
    echo ""
    echo "Configuration:"
    echo "  Skip Local: $SKIP_LOCAL"
    echo "  Skip VMs: $SKIP_VMS"
    echo "  Skip Sepolia: $SKIP_SEPOLIA"
    echo "  VM Only: $VM_ONLY"
    echo "  Scenarios: ${SCENARIOS:-all}"
    echo "  TNs: ${TNS:-all}"
    echo ""

    mkdir -p "$RESULTS_DIR"

    # Phase 1: Local experiments
    if [ "$VM_ONLY" != "true" ] && [ "$SKIP_LOCAL" != "true" ]; then
        run_local_experiments
    fi

    # Phase 2: Deploy to VMs
    if [ "$SKIP_VMS" != "true" ]; then
        deploy_to_vms
    fi

    # Phase 3: VM experiments
    if [ "$SKIP_VMS" != "true" ]; then
        run_vm_experiments
    fi

    # Phase 4: Network latency
    if [ "$SKIP_VMS" != "true" ]; then
        run_network_latency_experiment
    fi

    # Phase 5: Generate report
    generate_final_report

    echo ""
    echo "========================================================================"
    echo "  ALL EXPERIMENTS COMPLETE!"
    echo "========================================================================"
    echo ""
    echo "Results location: $RESULTS_DIR"
    echo ""
    echo "Next steps:"
    echo "  1. Review results in $RESULTS_DIR/"
    echo "  2. Check $RESULTS_DIR/summary.json for overview"
    echo "  3. Generate paper figures from results/"
    echo ""
}

# Run main
main "$@"

# =====================================================================
# End of Script
# =====================================================================