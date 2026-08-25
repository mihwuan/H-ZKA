#!/usr/bin/env bash
# Reproduce every second-revision protocol experiment (E1-E12).
#
#   bash run_all.sh            # full configuration used in the manuscript
#   SEEDS=5 bash run_all.sh    # fast smoke run
#
# Trace-calibrated simulation (TODO Item 7):
#   TOPOLOGY_FILE=sample_topology.json bash run_all.sh
#
# Requirements: Python >= 3.9 with numpy >= 1.24.  No plotting library is
# needed; each script writes CSV/JSON into ../../result/revision2 and the
# manuscript renders figures from those files with pgfplots.

set -euo pipefail
cd "$(dirname "$0")"

SEEDS="${SEEDS:-30}"
ROUNDS="${ROUNDS:-260}"
K="${K:-100}"
SEED="${SEED:-20260822}"
TOPO="${TOPOLOGY_FILE:-}"

# Build the topology-file argument if provided
TOPO_ARG=""
if [ -n "${TOPO}" ]; then
    TOPO_ARG="--topology-file ${TOPO}"
    echo "Using trace-calibrated topology: ${TOPO}"
fi

echo "== environment =="
python3 --version
python3 -c "import numpy; print('numpy', numpy.__version__)"
echo "seeds=${SEEDS} rounds=${ROUNDS} k=${K} base_seed=${SEED}"
echo

echo "== E1: Byzantine ratio, churn, heterogeneous delay =="
python3 exp_byzantine_churn.py --seeds "${SEEDS}" --rounds "${ROUNDS}" --k "${K}" --seed "${SEED}" ${TOPO_ARG}

echo
echo "== E2: strategic, adaptive, and colluding adversaries =="
python3 exp_adaptive_adversary.py --seeds "${SEEDS}" --rounds 500 --k "${K}" --seed "${SEED}" ${TOPO_ARG}

echo
echo "== E3: clustering-policy ablation =="
python3 exp_clustering_ablation.py --seeds "${SEEDS}" --k "${K}" --seed "${SEED}" ${TOPO_ARG}

echo
echo "== E4: audit-layer leakage quantification =="
python3 exp_leakage.py --seeds "${SEEDS}" --rounds 400 --k "${K}" --seed "${SEED}"

echo
echo "== E5: cluster-head fault recovery =="
python3 exp_fault_recovery.py --seeds "${SEEDS}" --rounds "${ROUNDS}" --k "${K}" --seed "${SEED}" ${TOPO_ARG}

echo
echo "== E6: per-stage communication and storage accounting =="
python3 exp_overhead_model.py

echo
echo "== E7: exact on-chain verification cost from the EVM gas schedule =="
python3 exp_onchain_cost.py

echo
echo "== E8: two-stage prover accounting (inner proofs + aggregation) =="
python3 exp_prover_pipeline.py

echo
echo "== E9: per-cluster BFT condition and captured-cluster behavior =="
python3 exp_bft_bound.py --seeds "${SEEDS}" --rounds "${ROUNDS}" --k "${K}" --seed "${SEED}" ${TOPO_ARG}

echo
echo "== E10: cluster-count and arrival-burstiness sensitivity =="
python3 exp_config_sensitivity.py --seeds "${SEEDS}" --rounds "${ROUNDS}" --k "${K}" --seed "${SEED}" ${TOPO_ARG}

echo
echo "== E11: alternative proving backend (Nova/HyperNova folding) =="
python3 exp_nova_backend.py

echo
echo "== E12: reputation-DoS equilibrium (frivolous-challenge deterrence) =="
python3 exp_reputation_dos.py --seeds "${SEEDS}" --rounds "${ROUNDS}" --k "${K}" --seed "${SEED}"

echo
echo "All experiments complete.  Results in ../../result/revision2/"

