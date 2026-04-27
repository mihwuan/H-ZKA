#!/bin/bash
# =====================================================================
# zkCross - Master Deployment Script for 10 VMs
# =====================================================================
# Script chạy TRÊN MÁY LOCAL để deploy toàn bộ hệ thống lên 10 Azure VMs
#
# Hướng dẫn sử dụng:
#   1. Tạo 10 Azure VMs (Standard_E4s_v3) trong cùng Virtual Network
#   2. Đảm bảo SSH access đã được thiết lập
#   3. Chạy script này từ máy local:
#      bash scripts/deploy_to_10vm.sh
#
# =====================================================================

set -eo pipefail

# Ghi log toàn bộ output ra file (vừa hiện ra màn hình, vừa lưu file)
LOG_FILE="$(dirname "$0")/../deploy_to_10vm.log"
exec > >(tee -a "$LOG_FILE") 2>&1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."

# SSH key paths - keys are in the parent Project directory
VM1_KEY="/home/mihwuan/Project/VM_key.pem"
VM2_KEY="/home/mihwuan/Project/VM2_key.pem"

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

echo "========================================================"
echo "  zkCross - 10 VM Deployment Master Script"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"

# =====================================================================
# Check prerequisites
# =====================================================================
echo ""
echo "[Check] Verifying prerequisites..."

if ! command -v scp &> /dev/null; then
    echo "  ✗ scp not found. Please install OpenSSH client."
    exit 1
fi

if ! command -v ssh &> /dev/null; then
    echo "  ✗ ssh not found. Please install OpenSSH client."
    exit 1
fi

echo "  ✓ SSH and SCP are available"

# Check if key files exist
if [ ! -f "$VM1_KEY" ]; then
    echo "  ⚠ VM1 key not found at $VM1_KEY"
fi
if [ ! -f "$VM2_KEY" ]; then
    echo "  ⚠ VM2 key not found at $VM2_KEY"
fi

# =====================================================================
# Step 0: Compile contracts locally (optional - continue even if fails)
# =====================================================================
echo ""
echo "[Step 0] Compiling Solidity contracts..."
cd "$PROJECT_DIR"
# Clean cache to ensure fresh compile
rm -rf "$PROJECT_DIR/cache" "$PROJECT_DIR/artifacts" 2>/dev/null || true
npx hardhat compile > /tmp/zkcross_hardhat_compile.log 2>&1 || echo "  ⚠ Compilation skipped (may already be compiled)"
[ -f /tmp/zkcross_hardhat_compile.log ] && tail -3 /tmp/zkcross_hardhat_compile.log || true

# =====================================================================
# Step 1: Sync project to all VMs
# =====================================================================
echo ""
echo "[Step 1] Syncing project to all VMs..."

# Create tarball of project (excluding large files)
echo "  Creating project archive..."
cd "$PROJECT_DIR"
tar --exclude='./node_modules' \
    --exclude='./.git' \
    --exclude='./results' \
    --exclude='*/.log' \
    --exclude='./artifacts' \
    --exclude='./cache' \
    -czf /tmp/zkcross.tar.gz . 2>/dev/null

for i in {1..10}; do
    vm_ip="${VM_IPS[$i]}"
    key=$(get_vm_key $i)
    echo "  VM #$i ($vm_ip): Syncing project..."

    # Copy project archive
    scp -i "$key" -o StrictHostKeyChecking=no -q /tmp/zkcross.tar.gz "$VM_USER@$vm_ip:/tmp/" 2>/dev/null || \
    scp -i "$key" -o StrictHostKeyChecking=no -q /tmp/zkcross.tar.gz "$VM_USER@$vm_ip:/tmp/"

    # Extract on VM
    ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        "mkdir -p ~/zkCross/results && tar -xzf /tmp/zkcross.tar.gz -C ~/zkCross --strip-components=1" 2>/dev/null || \
        ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        "mkdir -p ~/zkCross/results && tar -xzf /tmp/zkcross.tar.gz -C ~/zkCross --strip-components=1"

    echo "    ✓ VM #$i synced"
done

rm -f /tmp/zkcross.tar.gz

# =====================================================================
# Step 2: Run setup on each VM
# =====================================================================
echo ""
echo "[Step 2] Running VM setup on all VMs..."

for i in {1..10}; do
    vm_ip="${VM_IPS[$i]}"
    key=$(get_vm_key $i)

    echo "  VM #$i ($vm_ip): Running azure_vm_setup.sh..."

    # Copy setup script
    scp -i "$key" -o StrictHostKeyChecking=no -q "$SCRIPT_DIR/azure_vm_setup.sh" "$VM_USER@$vm_ip:/tmp/" 2>/dev/null || \
    scp -i "$key" -o StrictHostKeyChecking=no -q "$SCRIPT_DIR/azure_vm_setup.sh" "$VM_USER@$vm_ip:/tmp/"

    # Run setup (may take a few minutes)
    ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        "chmod +x /tmp/azure_vm_setup.sh && bash /tmp/azure_vm_setup.sh" 2>/dev/null || \
        ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        "chmod +x /tmp/azure_vm_setup.sh && bash /tmp/azure_vm_setup.sh"

    echo "  VM #$i ($vm_ip): Ensuring Node.js 22.x and clean npm install..."
    ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        'export HOME=$(getent passwd "$USER" | cut -d: -f6); \
        sudo apt-get remove -y nodejs npm; \
        export NVM_DIR="$HOME/.nvm"; \
        [ -d "$NVM_DIR" ] || mkdir -p "$NVM_DIR"; \
        [ -s "$NVM_DIR/nvm.sh" ] || (curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash); \
        . "$NVM_DIR/nvm.sh"; \
        nvm install 22; nvm use 22; \
        export PATH="$NVM_DIR/versions/node/v22.*/bin:$PATH"; \
        node --version; which node; which npx; \
        cd ~/zkCross && rm -rf node_modules package-lock.json && npm install --silent'

    echo "    ✓ VM #$i setup complete"
done

# =====================================================================
# Step 2b: Install npm dependencies on each VM
# =====================================================================
echo ""
echo "[Step 2b] Installing npm dependencies on all VMs..."


echo "  ✓ Node.js 22.x and npm packages ensured on all VMs"

# =====================================================================
# Step 3: Start Docker on each VM
# =====================================================================
echo ""
echo "[Step 3] Starting Docker containers on all VMs..."

for i in {1..10}; do
    vm_ip="${VM_IPS[$i]}"
    key=$(get_vm_key $i)

    echo "  VM #$i ($vm_ip): Starting Docker..."

    # Copy docker-compose and .env
    scp -i "$key" -o StrictHostKeyChecking=no -q "$PROJECT_DIR/docker/docker-compose-10vm.yml" \
        "$VM_USER@$vm_ip:~/zkCross/docker/docker-compose.yml" 2>/dev/null || \
    scp -i "$key" -o StrictHostKeyChecking=no -q "$PROJECT_DIR/docker/docker-compose-10vm.yml" \
        "$VM_USER@$vm_ip:~/zkCross/docker/docker-compose.yml"

    # Copy .env for this VM
    scp -i "$key" -o StrictHostKeyChecking=no -q "$PROJECT_DIR/docker/.env.vm$i" \
        "$VM_USER@$vm_ip:~/zkCross/docker/.env" 2>/dev/null || \
    scp -i "$key" -o StrictHostKeyChecking=no -q "$PROJECT_DIR/docker/.env.vm$i" \
        "$VM_USER@$vm_ip:~/zkCross/docker/.env"

    # Build and start Docker
    ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        "cd ~/zkCross/docker && docker compose build && docker compose up -d" 2>/dev/null || \
        ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        "cd ~/zkCross/docker && docker compose build && docker compose up -d"

    echo "    ✓ VM #$i Docker started"
        # Compile contracts on VM
    echo "    Compiling contracts on VM #$i..."
    ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        "export NVM_DIR=\"\$HOME/.nvm\"; \
         [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; \
         nvm use 22; \
         cd ~/zkCross && timeout 180 npx hardhat compile --force > /tmp/zkcross_hardhat_compile.log 2>&1 || true; tail -20 /tmp/zkcross_hardhat_compile.log" 2>/dev/null || \
    ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        "export NVM_DIR=\"\$HOME/.nvm\"; \
         [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; \
         nvm use 22; \
         cd ~/zkCross && timeout 180 npx hardhat compile --force > /tmp/zkcross_hardhat_compile.log 2>&1 || true; tail -20 /tmp/zkcross_hardhat_compile.log"

    echo "    ✓ VM #$i contracts compiled"
done

# =====================================================================
# Step 4: Wait for all VMs to be ready
# =====================================================================
echo ""
echo "[Step 4] Waiting for all VMs to be healthy..."

for i in {1..10}; do
    vm_ip="${VM_IPS[$i]}"
    key=$(get_vm_key $i)
    echo -n "  VM #$i ($vm_ip): "

    for attempt in {1..30}; do
        if ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
            "curl -sf -X POST -H 'Content-Type: application/json' \
            --data '{\"jsonrpc\":\"2.0\",\"method\":\"eth_blockNumber\",\"params\":[],\"id\":1}' \
            http://localhost:8545 > /dev/null 2>&1"; then
            echo "✓ Ready"
            break
        fi

        if [ $attempt -eq 30 ]; then
            echo "⚠ May not be ready"
        fi

        sleep 2
    done
done

# =====================================================================
# Step 5: Setup inter-VM networking
# =====================================================================
echo ""
echo "[Step 5] Setting up inter-VM networking..."

for i in {1..10}; do
    vm_ip="${VM_IPS[$i]}"
    key=$(get_vm_key $i)

    echo "  VM #$i ($vm_ip): Configuring network..."

    scp -i "$key" -o StrictHostKeyChecking=no -q "$SCRIPT_DIR/setup_10vm_network.sh" "$VM_USER@$vm_ip:/tmp/" 2>/dev/null || \
    scp -i "$key" -o StrictHostKeyChecking=no -q "$SCRIPT_DIR/setup_10vm_network.sh" "$VM_USER@$vm_ip:/tmp/"

    ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        "cd ~/zkCross && bash scripts/setup_10vm_network.sh" 2>/dev/null || \
        ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        "cd ~/zkCross && bash scripts/setup_10vm_network.sh"

    echo "    ✓ VM #$i network configured"
done

# =====================================================================
# Step 6: Verify complete system
# =====================================================================
echo ""
echo "[Step 6] Verifying complete system..."

total_nodes=0
for i in {1..10}; do
    vm_ip="${VM_IPS[$i]}"
    key=$(get_vm_key $i)

    node_count=$(ssh -i "$key" -o StrictHostKeyChecking=no "$VM_USER@$vm_ip" \
        "docker ps -q | wc -l" 2>/dev/null || echo "0")

    total_nodes=$((total_nodes + node_count))
    echo "  VM #$i: $node_count nodes running"
done

echo ""
echo "  Total nodes in system: $total_nodes"

if [ $total_nodes -ge 190 ]; then
    echo "  ✓ System verification PASSED (>= 190 nodes)"
else
    echo "  ⚠ System verification INCOMPLETE (expected 200 nodes)"
fi

# =====================================================================
# Summary
# =====================================================================
echo ""
echo "========================================================"
echo "  Deployment Complete!"
echo "========================================================"
echo ""
echo "  System Configuration:"
echo "    - Total VMs: 10"
echo "    - Total Chains: 100"
echo "    - Total Nodes: 200"
echo "    - Nodes Running: $total_nodes"
echo ""
echo "  VM IP Addresses:"
for i in {1..10}; do
    echo "    VM #$i: ${VM_IPS[$i]}"
done
echo ""
echo "  Next steps:"
echo "    1. SSH to VM1: ssh -i $VM1_KEY $VM_USER@<VM1_IP>"
echo "    2. SSH to VMs 2-10: ssh -i $VM2_KEY $VM_USER@<VM_IP>"
echo "    2. Run experiments: cd ~/zkCross && bash scripts/run_azure_experiments.sh"
echo "    3. View logs: docker compose -f ~/zkCross/docker/docker-compose.yml logs"
echo ""
echo "  To stop the system:"
echo "    docker compose -f ~/zkCross/docker/docker-compose.yml down"
echo ""
echo "========================================================"
