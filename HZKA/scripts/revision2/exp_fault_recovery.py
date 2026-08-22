#!/usr/bin/env python3
"""Experiment E5: fault-recovery behaviour under cluster-head failure.

Hierarchical aggregation concentrates responsibility: a failed cluster head
stalls every chain in its cluster, whereas a failed per-chain committer in the
flat baseline stalls one chain.  This experiment quantifies both the
concentration penalty and the cost of the in-round re-election that bounds it.

Measured quantities
-------------------
* round completion rate: fraction of clusters that commit a fresh slot;
* recovery latency: additional round latency caused by the failover timeout;
* stalled-chain amplification relative to the flat baseline;
* rounds to return to the pre-failure steady-state audit accuracy.

Outputs
-------
result/revision2/e5_fault_recovery.csv
result/revision2/e5_summary.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
from typing import Dict, List

import numpy as np

from hzka_protocol_sim import (Adversary, HZKASimulation, NetworkProfile,
                               SimConfig)

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "result", "revision2")


def run_grid(seeds: int, rounds: int, k: int, base_seed: int) -> List[Dict]:
    rows: List[Dict] = []
    n_clusters = int(math.ceil(math.sqrt(k)))
    b = k / float(n_clusters)

    for crash in [0.0, 0.01, 0.05, 0.10, 0.20]:
        coord, acc, recov = [], [], []
        stalled_mean, stalled_sd, flat_mean, flat_sd = [], [], [], []
        worst, cluster_out = [], []
        for s in range(seeds):
            cfg = SimConfig(k=k, rounds=rounds, byz_frac=0.20,
                            head_crash_prob=crash,
                            adversary=Adversary(kind="naive"),
                            profile=NetworkProfile(loss=0.02))
            sim = HZKASimulation(cfg, seed=base_seed + 5000 + s)
            hist = sim.run()
            coord.append(np.mean([h.coordination_ms for h in hist]))
            acc.append(np.mean([h.audit_accuracy for h in hist[rounds // 2:]]))
            stalls = np.array([h.stalled_chains for h in hist], dtype=float)
            flats = np.array([h.flat_stalled_chains for h in hist], dtype=float)
            stalled_mean.append(stalls.mean())
            stalled_sd.append(stalls.std(ddof=1) if stalls.size > 1 else 0.0)
            flat_mean.append(flats.mean())
            flat_sd.append(flats.std(ddof=1) if flats.size > 1 else 0.0)
            worst.append(float(np.percentile(stalls, 95)))
            cluster_out.append(np.mean([h.stalled_clusters > 0 for h in hist]))
            traj = np.array([h.audit_accuracy for h in hist])
            target = 0.99 * traj[rounds // 2:].mean()
            idx = np.where(traj >= target)[0]
            recov.append(float(idx[0] + 1) if idx.size else float(rounds))

        rows.append({
            "head_crash_prob": crash,
            "coordination_ms_mean": float(np.mean(coord)),
            "coordination_ms_ci": float(1.96 * np.std(coord, ddof=1) / np.sqrt(seeds)),
            "steady_accuracy_mean": float(np.mean(acc)),
            "stalled_chains_mean_hzka": float(np.mean(stalled_mean)),
            "stalled_chains_sd_hzka": float(np.mean(stalled_sd)),
            "stalled_chains_mean_flat": float(np.mean(flat_mean)),
            "stalled_chains_sd_flat": float(np.mean(flat_sd)),
            "burst_amplification": (float(np.mean(stalled_sd) / np.mean(flat_sd))
                                    if np.mean(flat_sd) > 0 else 0.0),
            "p95_stalled_chains_hzka": float(np.mean(worst)),
            "rounds_with_cluster_outage": float(np.mean(cluster_out)),
            "avg_cluster_size": float(b),
            "recovery_round_mean": float(np.mean(recov)),
        })
    # relative overhead against the crash-free configuration
    ref = rows[0]["coordination_ms_mean"]
    for r in rows:
        r["coordination_overhead_pct"] = 100.0 * (r["coordination_ms_mean"] - ref) / ref
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
    ap.add_argument("--seeds", type=int, default=30)
    ap.add_argument("--rounds", type=int, default=200)
    ap.add_argument("--k", type=int, default=100)
    ap.add_argument("--seed", type=int, default=20260822)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)

    rows = run_grid(args.seeds, args.rounds, args.k, args.seed)
    write_csv(os.path.join(OUT, "e5_fault_recovery.csv"), rows)
    with open(os.path.join(OUT, "e5_summary.json"), "w", encoding="utf-8") as fh:
        json.dump({"config": vars(args), "rows": rows}, fh, indent=2)

    print("E5 complete.")
    for r in rows:
        print(f"  p_crash={r['head_crash_prob']:.2f} coord={r['coordination_ms_mean']:8.1f}ms "
              f"(+{r['coordination_overhead_pct']:5.1f}%) "
              f"stall mu={r['stalled_chains_mean_hzka']:.2f}/{r['stalled_chains_mean_flat']:.2f} "
              f"sd={r['stalled_chains_sd_hzka']:.2f}/{r['stalled_chains_sd_flat']:.2f} "
              f"burst={r['burst_amplification']:.2f}x acc={r['steady_accuracy_mean']:.4f}")


if __name__ == "__main__":
    main()
