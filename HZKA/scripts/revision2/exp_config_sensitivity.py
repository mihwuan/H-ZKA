#!/usr/bin/env python3
"""Experiment E10: cluster-count sensitivity and bursty workload arrival.

Part A -- the (M, B) trade-off.  The manuscript fixes M = ceil(sqrt(k)), but
that choice is not forced by anything except the asymptotic argument.  Sweeping
M at fixed k exposes a tension that the square-root rule sits in the middle of:

  * larger clusters (small M) reduce the number of on-chain verifications and
    therefore gas, but enlarge the aggregation circuit, raise per-head memory,
    and increase padding waste when clusters are under-occupied;
  * smaller clusters (large M) shrink the circuit but raise on-chain cost and,
    critically, *lower the absolute Byzantine count needed to break the
    per-cluster BFT condition*, because the threshold is ceil(B/3).

The third effect was not previously reported and works against small clusters.

Part B -- bursty arrivals.  Round completeness and queue occupancy under
Poisson versus Markov-modulated (bursty) workload arrival at equal mean rate.

Outputs
-------
result/revision2/e10_cluster_config.csv
result/revision2/e10_burstiness.csv
result/revision2/e10_summary.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
from typing import Dict, List

import numpy as np

from exp_onchain_cost import (GROTH16_PAIRS, G_PAIRING_BASE,
                              G_PAIRING_PER_PAIR, hzka_cluster_tx, total)
from exp_bft_bound import analytic_capture_prob

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "result", "revision2")

GIB_PER_MCONSTRAINT = 24.0 / 8.0
C_BASE_M = 0.8                 # constant part of the aggregation circuit
C_VERIFY_M = 1.28              # per-inner-proof recursive verification cost
SEC_PER_MCONSTRAINT = 4.567686


def agg_constraints_m(b_max: int) -> float:
    """C_agg(B) = C_base + B * C_verify + C_tree(B), manuscript Eq. (25).

    Calibrated so that B_max = 15 reproduces the 20M figure used throughout.
    """
    tree = 0.0036 * math.ceil(math.log2(max(2, b_max)))   # Poseidon binding
    return C_BASE_M + b_max * C_VERIFY_M + tree


def part_a(k: int, f_byz: float) -> List[Dict]:
    rows: List[Dict] = []
    for m in (4, 5, 8, 10, 13, 20, 25):
        b = math.ceil(k / m)
        b_max = b                       # compiled exactly for this occupancy
        c_m = agg_constraints_m(b_max)
        tx = total(hzka_cluster_tx(b_max, "commitment"))
        pairing = m * (G_PAIRING_BASE + GROTH16_PAIRS * G_PAIRING_PER_PAIR)
        rows.append({
            "k": k,
            "clusters_m": m,
            "cluster_size_b": b,
            "is_sqrt_rule": int(m == math.ceil(math.sqrt(k))),
            "agg_constraints_millions": c_m,
            "agg_prover_seconds": SEC_PER_MCONSTRAINT * c_m,
            "agg_memory_gib": c_m * GIB_PER_MCONSTRAINT,
            "onchain_gas_round": m * tx,
            "onchain_pairing_gas": pairing,
            "bft_threshold": math.ceil(b / 3.0),
            "capture_prob": analytic_capture_prob(k, m, f_byz),
            "expected_captured_clusters": m * analytic_capture_prob(k, m, f_byz),
            "total_agg_work_seconds": m * SEC_PER_MCONSTRAINT * c_m,
        })
    return rows


def part_b(seeds: int, rounds: int, k: int, base_seed: int) -> List[Dict]:
    """Round completeness under Poisson versus bursty arrival.

    Utilisation is swept separately from burstiness so that the two effects are
    not confounded: a queue at rho = 0.99 degrades under any arrival process.
    Bursty arrival is Markov-modulated, alternating between a quiet and a busy
    state at the same long-run mean rate.
    """
    rows: List[Dict] = []
    mean_jobs = float(k)
    for rho in (0.5, 0.7, 0.9):
        capacity = mean_jobs / rho
        for mode, burst in (("poisson", 1.0), ("bursty-3x", 3.0),
                            ("bursty-6x", 6.0)):
            p95, mean_backlog, complete = [], [], []
            for s in range(seeds):
                rng = np.random.default_rng(base_seed + 10_000 + s
                                            + int(rho * 100) + int(burst))
                if burst == 1.0:
                    arrivals = rng.poisson(mean_jobs, size=rounds).astype(float)
                else:
                    busy = rng.random(rounds) < (1.0 / burst)
                    arrivals = rng.poisson(
                        np.where(busy, mean_jobs * burst, 0.0)).astype(float)
                backlog, series = 0.0, []
                for a in arrivals:
                    backlog = max(0.0, backlog + a - capacity)
                    series.append(backlog)
                series = np.array(series)
                p95.append(float(np.percentile(series, 95)))
                mean_backlog.append(float(series.mean()))
                # A round is late when the standing backlog exceeds one round
                # of service capacity.
                complete.append(float(np.mean(series <= capacity)))
            rows.append({
                "target_utilisation": rho,
                "arrival_mode": mode,
                "burst_ratio": burst,
                "capacity_jobs_per_round": capacity,
                "mean_backlog_jobs": float(np.mean(mean_backlog)),
                "backlog_p95_jobs": float(np.mean(p95)),
                "round_on_time_frac": float(np.mean(complete)),
            })
    return rows


def write_csv(path: str, rows: List[Dict]) -> None:
    cols = list(rows[0].keys())
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(",".join(cols) + "\n")
        for r in rows:
            fh.write(",".join(
                f"{r[c]:.6f}" if isinstance(r[c], float) else str(r[c])
                for c in cols) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=15)
    ap.add_argument("--rounds", type=int, default=200)
    ap.add_argument("--k", type=int, default=100)
    ap.add_argument("--byz", type=float, default=0.20)
    ap.add_argument("--seed", type=int, default=20260822)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)

    a = part_a(args.k, args.byz)
    write_csv(os.path.join(OUT, "e10_cluster_config.csv"), a)
    b = part_b(args.seeds, args.rounds, args.k, args.seed)
    write_csv(os.path.join(OUT, "e10_burstiness.csv"), b)

    with open(os.path.join(OUT, "e10_summary.json"), "w", encoding="utf-8") as fh:
        json.dump({"config": vars(args), "cluster_config": a,
                   "burstiness": b}, fh, indent=2)

    print("E10 complete.\n")
    print("Part A: cluster-count trade-off at k=%d, Byzantine ratio %.2f" % (args.k, args.byz))
    print("    M    B  sqrt?  C_agg(M)  prove(s)  mem(GiB)  gas/round   thr  P[capture]  E[captured]")
    for r in a:
        print("  %3d %4d    %s   %7.2f  %8.1f  %8.1f  %9d  %4d      %.4f       %.2f"
              % (r["clusters_m"], r["cluster_size_b"],
                 "*" if r["is_sqrt_rule"] else " ",
                 r["agg_constraints_millions"], r["agg_prover_seconds"],
                 r["agg_memory_gib"], r["onchain_gas_round"],
                 r["bft_threshold"], r["capture_prob"],
                 r["expected_captured_clusters"]))
    print("\nPart B: bursty arrival at equal mean rate, utilisation held fixed")
    print("   rho  mode        mean backlog  p95 backlog  on-time")
    for r in b:
        print("  %.1f  %-10s %11.1f %12.1f   %.4f"
              % (r["target_utilisation"], r["arrival_mode"],
                 r["mean_backlog_jobs"], r["backlog_p95_jobs"],
                 r["round_on_time_frac"]))


if __name__ == "__main__":
    main()
