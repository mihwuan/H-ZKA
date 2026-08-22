#!/usr/bin/env bash
# Reproduce every second-revision protocol experiment (E1-E6).
#
#   bash run_all.sh            # full configuration used in the manuscript
#   SEEDS=5 bash run_all.sh    # fast smoke run
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

echo "== environment =="
python3 --version
python3 -c "import numpy; print('numpy', numpy.__version__)"
echo "seeds=${SEEDS} rounds=${ROUNDS} k=${K} base_seed=${SEED}"
echo

echo "== E1: Byzantine ratio, churn, heterogeneous delay =="
python3 exp_byzantine_churn.py --seeds "${SEEDS}" --rounds "${ROUNDS}" --k "${K}" --seed "${SEED}"

echo
echo "== E2: strategic, adaptive, and colluding adversaries =="
python3 exp_adaptive_adversary.py --seeds "${SEEDS}" --rounds 500 --k "${K}" --seed "${SEED}"

echo
echo "== E3: clustering-policy ablation =="
python3 exp_clustering_ablation.py --seeds "${SEEDS}" --k "${K}" --seed "${SEED}"

echo
echo "== E4: audit-layer leakage quantification =="
python3 exp_leakage.py --seeds "${SEEDS}" --rounds 400 --k "${K}" --seed "${SEED}"

echo
echo "== E5: cluster-head fault recovery =="
python3 exp_fault_recovery.py --seeds "${SEEDS}" --rounds "${ROUNDS}" --k "${K}" --seed "${SEED}"

echo
echo "== E6: per-stage communication and storage accounting =="
python3 exp_overhead_model.py

echo
echo "All experiments complete.  Results in ../../result/revision2/"
