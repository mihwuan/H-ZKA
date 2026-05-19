#!/bin/bash
# =====================================================================
# zkCross v2 — Azure VM Setup Script
# =====================================================================
# VM: Standard E4s v3 (4 vCPUs, 32 GiB RAM), Ubuntu 22.04
# Chạy 1 lần duy nhất sau khi SSH vào VM
#
# Cách dùng:
#   scp -i VM_key.pem azure_vm_setup.sh azureuser@<IP>:~/
#   ssh -i VM_key.pem azureuser@<IP>
#   chmod +x ~/azure_vm_setup.sh && ~/azure_vm_setup.sh
# =====================================================================

set -e

echo "========================================================"
echo "  zkCross v2 — Azure VM Setup"
echo "  VM: Standard E4s v3 (4 vCPUs, 32GB RAM)"
echo "========================================================"

# ---- 1. System packages ----
echo ""
echo "[1/6] Installing system packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
    curl wget git build-essential \
    python3 python3-pip python3-venv \
    iproute2 net-tools jq \
    ca-certificates gnupg lsb-release

# ---- 2. Docker ----
echo ""
echo "[2/6] Installing Docker..."
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker $USER
    echo "  ✓ Docker installed (cần logout/login lại để dùng không sudo)"
else
    echo "  ✓ Docker already installed: $(docker --version)"
fi

# Đảm bảo Docker daemon chạy
if [ -f /snap/bin/docker ]; then
    # Docker installed via snap - use snap services
    echo "  ✓ Docker from snap detected"
    sudo snap start docker 2>/dev/null || true
    # Fix snap docker socket permissions
    sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
else
    # Docker from official install
    sudo systemctl enable docker 2>/dev/null || true
    sudo systemctl start docker 2>/dev/null || true
    # Ensure user can access docker
    sudo chmod 666 /var/run/docker.sock 2>/dev/null || true
fi

# ---- 3. Node.js 20 LTS ----
echo ""
echo "[3/6] Installing Node.js 20 LTS..."
if ! command -v node &>/dev/null || [[ $(node -v | cut -d. -f1 | tr -d v) -lt 18 ]]; then
    # Remove conflicting packages first
    sudo apt-get remove -y -qq libnode-dev nodejs 2>/dev/null || true
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y -qq nodejs
    echo "  ✓ Node.js installed: $(node --version)"
else
    echo "  ✓ Node.js already installed: $(node --version)"
fi
# Fix npm/hardhat permissions for global packages
mkdir -p ~/.npm-global
npm config set prefix '~/.npm-global'
echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc
export PATH=~/.npm-global/bin:$PATH

# ---- 4. Python packages ----
echo ""
echo "[4/6] Installing Python packages..."
pip3 install --quiet numpy matplotlib scipy pandas

# ---- 5. Tạo swap (32GB RAM có thể không đủ cho prover lớn) ----
echo ""
echo "[5/6] Setting up swap (8GB)..."
if [ ! -f /swapfile ]; then
    sudo fallocate -l 8G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    echo "  ✓ 8GB swap created"
else
    echo "  ✓ Swap already exists"
fi

# ---- 6. Firewall (mở ports cho Docker nodes) ----
echo ""
echo "[6/6] Configuring firewall..."
sudo ufw allow 22/tcp    2>/dev/null || true
sudo ufw allow 8545/tcp  2>/dev/null || true
sudo ufw allow 8546/tcp  2>/dev/null || true
sudo ufw allow 8547/tcp  2>/dev/null || true
sudo ufw allow 8548/tcp  2>/dev/null || true
sudo ufw allow 30303/tcp 2>/dev/null || true

# ---- Summary ----
echo ""
echo "========================================================"
echo "  Setup Complete!"
echo "========================================================"
echo ""
echo "  Docker:  $(docker --version 2>/dev/null || echo 'cần relogin')"
echo "  Node.js: $(node --version 2>/dev/null || echo 'not found')"
echo "  Python:  $(python3 --version 2>/dev/null || echo 'not found')"
echo "  RAM:     $(free -h | awk '/Mem:/{print $2}')"
echo "  Swap:    $(free -h | awk '/Swap:/{print $2}')"
echo "  Disk:    $(df -h / | awk 'NR==2{print $4}') available"
echo ""
echo "  QUAN TRỌNG: Logout rồi SSH lại để Docker không cần sudo:"
echo "    exit"
echo "    ssh -i VM_key.pem azureuser@$(curl -s ifconfig.me 2>/dev/null || echo '<IP>')"
echo ""
echo "  Tiếp theo: chạy deploy_to_vm.sh trên máy local"
echo "========================================================"
