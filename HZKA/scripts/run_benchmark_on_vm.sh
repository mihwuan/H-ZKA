#!/bin/bash
# ═══════════════════════════════════════════════════════════
# Deploy & Run Groth16 Benchmark on Azure VM via SSH
# (PLAN D: The Official Docker Build Method)
# ═══════════════════════════════════════════════════════════

set -e

VM_IP="${1:?Usage: $0 <VM_IP> <SSH_KEY_PATH>}"
SSH_KEY="${2:?Usage: $0 <VM_IP> <SSH_KEY_PATH>}"
VM_USER="${3:-azureuser}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOCAL_RESULTS="$PROJECT_DIR/results/vm_benchmark"
REMOTE_DIR="/home/$VM_USER/groth16_bench"

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=10"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

ssh_run() { ssh $SSH_OPTS "$VM_USER@$VM_IP" "$@"; }
scp_to() { scp $SSH_OPTS "$1" "$VM_USER@$VM_IP:$2"; }
scp_from() { scp $SSH_OPTS "$VM_USER@$VM_IP:$1" "$2"; }

log "Testing SSH to $VM_IP..."
ssh_run "echo 'SSH OK'; uname -a; free -h | head -2"
echo ""

log "Installing dependencies on VM (This may take ~5-7 mins)..."
ssh_run bash <<'INSTALL_EOF'
set -e

if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# Cài đặt công cụ và thư viện cho Rapidsnark C++
sudo apt-get update 2>/dev/null || true
sudo apt-get install -y build-essential git curl docker.io libstdc++6 nasm libgmp-dev libsodium-dev libomp-dev 2>/dev/null || true
sudo systemctl start docker || true

if ! command -v cargo &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"
fi
export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v circom &>/dev/null; then
    git clone https://github.com/iden3/circom.git /tmp/circom_build 2>/dev/null || true
    cd /tmp/circom_build && git pull && cargo build --release
    sudo cp target/release/circom /usr/local/bin/
fi

if ! command -v snarkjs &>/dev/null; then
    sudo npm install -g snarkjs
fi

# Dọn dẹp file rác
if [ -f /usr/local/bin/prover ]; then
    size=$(stat -c%s /usr/local/bin/prover)
    if [ "$size" -lt 100000 ]; then
        sudo rm -f /usr/local/bin/prover
    fi
fi

# RAPIDSNARK (PRECOMPILED BINARY v0.0.3 - FASTEST & SAFEST)
if ! command -v prover &>/dev/null; then
    echo "Downloading precompiled Rapidsnark Prover v0.0.3..."
    sudo apt-get install -y unzip 2>/dev/null || true
    rm -rf /tmp/rapidsnark_bin
    mkdir -p /tmp/rapidsnark_bin
    cd /tmp/rapidsnark_bin
    
    # Tải file zip release từ github (v0.0.3 tương thích tốt với Ubuntu 22.04)
    curl -f -L -o rapidsnark.zip "https://github.com/iden3/rapidsnark/releases/download/v0.0.3/rapidsnark-linux-x86_64-v0.0.3.zip"
    unzip rapidsnark.zip
    
    # Copy file thực thi
    sudo cp rapidsnark-linux-x86_64-v0.0.3/bin/prover /usr/local/bin/prover
    sudo chmod +x /usr/local/bin/prover
    echo "Rapidsnark Prover installed successfully!"
fi

echo "All dependencies ready."
INSTALL_EOF

log "Uploading benchmark script..."
ssh_run "mkdir -p $REMOTE_DIR"
scp_to "$SCRIPT_DIR/vm_groth16_benchmark.js" "$REMOTE_DIR/vm_groth16_benchmark.js"
log "Upload done."

log "Starting benchmark on VM (expect 20-40 min)..."
log "Streaming output..."
echo "═══════════════════════════════════════════════════════"

ssh_run bash <<BENCH_EOF
export PATH="/usr/local/bin:/usr/bin:\$HOME/.cargo/bin:\$(npm config get prefix 2>/dev/null)/bin:\$PATH"

if ! swapon --show | grep -q "/swapfile"; then
    echo "Swap is not active. Setting up 20GB swap..."
    # Nếu file chưa có thì mới tạo
    if [ ! -f /swapfile ]; then
        sudo fallocate -l 20G /swapfile
        sudo chmod 600 /swapfile
        sudo mkswap /swapfile
    fi
    # Bật swap
    sudo swapon /swapfile
fi

cd $REMOTE_DIR
export NODE_OPTIONS="--max-old-space-size=28672"
node vm_groth16_benchmark.js 2>&1 | tee benchmark.log
BENCH_EOF

echo "═══════════════════════════════════════════════════════"
log "Benchmark finished."

log "Downloading results..."
mkdir -p "$LOCAL_RESULTS"
scp_from "$REMOTE_DIR/bench_groth16/vm_benchmark_report.json" "$LOCAL_RESULTS/"
scp_from "$REMOTE_DIR/benchmark.log" "$LOCAL_RESULTS/"

log "DONE! Results saved to: $LOCAL_RESULTS/"