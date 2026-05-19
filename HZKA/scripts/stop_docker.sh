#!/bin/bash
# ==========================================
# zkCross - Stop Docker Containers
# ==========================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_DIR="$SCRIPT_DIR/../docker"

echo "============================================"
echo "  zkCross - Stopping Docker Containers"
echo "============================================"
echo ""

cd "$DOCKER_DIR"

# Stop and remove containers
echo "  Stopping containers..."
docker compose down -v 2>/dev/null || true

# Also kill any running geth processes
pkill -f "geth.*datadir.*testnet" 2>/dev/null || true

echo ""
echo "  ✓ All containers stopped"
echo "============================================"
