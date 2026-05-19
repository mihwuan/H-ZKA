#!/bin/bash
# ==========================================
# zkCross Docker Node Entrypoint
# ==========================================
# Environment variables:
#   GENESIS_FILE  - path to genesis JSON file (optional if CHAIN_ID is set)
#   CHAIN_ID      - numeric chain ID (used to auto-generate genesis)
#   SEALER_ADDRS  - comma-separated sealer addresses WITHOUT 0x prefix
#                   (used with CHAIN_ID to generate genesis extradata)
#   SEALER_KEY    - sealer private key (hex, no 0x prefix)
#   SEALER_ADDR   - sealer address (with 0x prefix)
#   NETWORK_ID    - chain/network ID
#   PEER_RPC      - RPC URL of peer to connect to (optional)

set -e

DATADIR=/data

# ---- 0. Auto-generate genesis if GENESIS_FILE not provided ----
if [ -z "$GENESIS_FILE" ] || [ ! -f "$GENESIS_FILE" ]; then
    if [ -z "$CHAIN_ID" ] || [ -z "$SEALER_ADDRS" ]; then
        echo "[error] Either GENESIS_FILE or (CHAIN_ID + SEALER_ADDRS) required"
        exit 1
    fi

    VANITY="0000000000000000000000000000000000000000000000000000000000000000"
    SEAL="0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"

    SIGNERS=""
    ALLOC=""
    IFS=',' read -ra ADDRS <<< "$SEALER_ADDRS"
    for i in "${!ADDRS[@]}"; do
        addr="${ADDRS[$i]}"
        addr_lower=$(echo "$addr" | tr '[:upper:]' '[:lower:]')
        SIGNERS="${SIGNERS}${addr_lower}"
        if [ $i -gt 0 ]; then ALLOC="${ALLOC},"; fi
        ALLOC="${ALLOC}
    \"${addr}\": { \"balance\": \"1000000000000000000000\" }"
    done
    EXTRADATA="0x${VANITY}${SIGNERS}${SEAL}"

    cat > /tmp/genesis.json <<GENESIS_EOF
{
  "config": {
    "chainId": ${CHAIN_ID},
    "homesteadBlock": 0, "eip150Block": 0, "eip155Block": 0, "eip158Block": 0,
    "byzantiumBlock": 0, "constantinopleBlock": 0, "petersburgBlock": 0,
    "istanbulBlock": 0, "berlinBlock": 0, "londonBlock": 0,
    "clique": { "period": 3, "epoch": 30000 }
  },
  "difficulty": "1",
  "gasLimit": "30000000",
  "extradata": "${EXTRADATA}",
  "alloc": {${ALLOC}
  }
}
GENESIS_EOF

    GENESIS_FILE="/tmp/genesis.json"
    echo "[genesis] Auto-generated for chainId=${CHAIN_ID} with ${#ADDRS[@]} sealers"
fi

# ---- 1. Initialize genesis ----
if [ ! -d "$DATADIR/geth/chaindata" ]; then
    echo "[init] Initializing genesis..."
    geth init --datadir "$DATADIR" "$GENESIS_FILE"
fi

# ---- 2. Import sealer key ----
echo "$SEALER_KEY" > /tmp/sealer.key
echo "" > /tmp/password.txt
geth account import --datadir "$DATADIR" --password /tmp/password.txt /tmp/sealer.key 2>/dev/null || true
rm -f /tmp/sealer.key

# ---- 3. Start geth ----
echo "[start] Starting geth (networkid=$NETWORK_ID, sealer=$SEALER_ADDR)..."
geth \
    --datadir "$DATADIR" \
    --networkid "$NETWORK_ID" \
    --port 30303 \
    --http --http.addr 0.0.0.0 --http.port 8545 \
    --http.api "eth,net,web3,txpool,debug,admin,personal,clique" \
    --http.corsdomain "*" \
    --http.vhosts "*" \
    --mine --miner.etherbase "$SEALER_ADDR" \
    --unlock "$SEALER_ADDR" \
    --password /tmp/password.txt \
    --allow-insecure-unlock \
    --nodiscover \
    --syncmode full \
    --gcmode archive \
    --verbosity 3 \
    &
GETH_PID=$!

# ---- 4. Wait for RPC ----
echo "[wait] Waiting for RPC to be ready..."
for i in $(seq 1 60); do
    if curl -sf http://localhost:8545 \
        -X POST -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        > /dev/null 2>&1; then
        echo "[ready] RPC is up."
        break
    fi
    sleep 1
done

# ---- 5. Connect to peer if PEER_RPC is set ----
if [ -n "$PEER_RPC" ]; then
    PEER_HOST=$(echo "$PEER_RPC" | sed 's|http://||;s|:.*||')
    PEER_PORT=$(echo "$PEER_RPC" | sed 's|.*:||')
    # Resolve hostname to IP (needed for enode URL and curl)
    PEER_IP=$(getent hosts "$PEER_HOST" | awk '{print $1}')
    if [ -z "$PEER_IP" ]; then
        PEER_IP="$PEER_HOST"
    fi
    # Use resolved IP for all RPC calls (Alpine curl can't resolve Docker DNS)
    PEER_RPC_IP="http://$PEER_IP:$PEER_PORT"
    echo "[peer] Peer host=$PEER_HOST ip=$PEER_IP rpc=$PEER_RPC_IP"

    add_peer() {
        PEER_ENODE=$(curl -sf "$PEER_RPC_IP" \
            -X POST -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}' \
            2>/dev/null | sed -n 's/.*"enode":"\([^"]*\)".*/\1/p' || echo "")
        if [ -n "$PEER_ENODE" ]; then
            PEER_ENODE=$(echo "$PEER_ENODE" | sed "s/@[^:]*:/@$PEER_IP:/")
            curl -sf http://localhost:8545 \
                -X POST -H "Content-Type: application/json" \
                -d "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"$PEER_ENODE\"],\"id\":1}" \
                2>/dev/null || true
        fi
    }

    # Initial peer connection (wait up to 90s)
    echo "[peer] Waiting for peer at $PEER_RPC_IP ..."
    for i in $(seq 1 90); do
        PEER_ENODE=$(curl -sf "$PEER_RPC_IP" \
            -X POST -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"admin_nodeInfo","params":[],"id":1}' \
            2>/dev/null | sed -n 's/.*"enode":"\([^"]*\)".*/\1/p' || echo "")
        if [ -n "$PEER_ENODE" ]; then
            PEER_ENODE=$(echo "$PEER_ENODE" | sed "s/@[^:]*:/@$PEER_IP:/")
            RESULT=$(curl -sf http://localhost:8545 \
                -X POST -H "Content-Type: application/json" \
                -d "{\"jsonrpc\":\"2.0\",\"method\":\"admin_addPeer\",\"params\":[\"$PEER_ENODE\"],\"id\":1}" \
                2>/dev/null || echo "failed")
            echo "[peer] addPeer result: $RESULT"
            break
        fi
        sleep 1
    done

    # Background loop: re-add peer every 15s if disconnected
    (
        while true; do
            sleep 15
            PEER_COUNT=$(curl -sf http://localhost:8545 \
                -X POST -H "Content-Type: application/json" \
                -d '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
                2>/dev/null | sed -n 's/.*"result":"\([^"]*\)".*/\1/p' || echo "0x0")
            if [ "$PEER_COUNT" = "0x0" ]; then
                add_peer
            fi
        done
    ) &
fi

# ---- 6. Keep running ----
wait $GETH_PID
