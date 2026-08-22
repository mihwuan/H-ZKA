#!/usr/bin/env python3
"""Experiment E9: the per-cluster BFT condition and captured-cluster behavior.

Why this exists
---------------
The security model requires f_l < |C_l|/3 live Byzantine members in every
cluster.  The earlier robustness sweep reported recovery to full honest control
at global Byzantine ratios up to 50%, which is outside that condition: with
B ~ 10 members per cluster, a global ratio well below 50% already produces
clusters holding four or more Byzantine members.  The earlier simulator
adjudicated faults in those clusters as though the adversarial quorum could not
interfere.

This experiment separates the two questions the previous sweep conflated.

Part A -- occupancy.  For each global Byzantine ratio, how many clusters
actually violate f_l < |C_l|/3?  Reported both analytically (hypergeometric)
and empirically.

Part B -- in-bound behavior.  Restricted to clusters that satisfy the
condition, does the MF-PoP transition still isolate Byzantine committers?

Part C -- captured-cluster behavior.  With ``model_capture`` enabled, a cluster
that breaks the condition censors adjudication for its members and withholds
its round slot.  What happens to global round completeness, to isolation, and
to recovery across an epoch reassignment boundary?

Outputs
-------
result/revision2/e9_bft_occupancy.csv
result/revision2/e9_capture.csv
result/revision2/e9_summary.json
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
FRACTIONS = [0.05, 0.10, 0.20, 0.30, 0.40, 0.50]


def hypergeom_pmf(N: int, K: int, n: int, x: int) -> float:
    if x < 0 or x > n or x > K or (n - x) > (N - K):
        return 0.0
    return (math.comb(K, x) * math.comb(N - K, n - x)) / math.comb(N, n)


def analytic_capture_prob(k: int, m: int, f: float) -> float:
    """P[a uniformly drawn cluster holds >= ceil(B/3) Byzantine members].

    Cluster membership is a size-B draw without replacement from k chains of
    which K = f*k are Byzantine, so the count is hypergeometric.
    """
    b = k // m
    kk = int(round(f * k))
    thr = int(math.ceil(b / 3.0))
    return sum(hypergeom_pmf(k, kk, b, x) for x in range(thr, b + 1))


def occupancy(seeds: int, k: int, base_seed: int) -> List[Dict]:
    rows: List[Dict] = []
    m = int(math.ceil(math.sqrt(k)))
    for f in FRACTIONS:
        emp, first_round_captured = [], []
        for s in range(seeds):
            cfg = SimConfig(k=k, rounds=2, byz_frac=f, model_capture=True,
                            adversary=Adversary(kind="naive"),
                            profile=NetworkProfile(loss=0.0, unresolved_rate=0.0))
            sim = HZKASimulation(cfg, seed=base_seed + 9000 + s)
            hist = sim.run()
            first_round_captured.append(hist[0].captured_clusters)
            emp.append(hist[0].captured_clusters / float(m))
        rows.append({
            "byz_frac": f,
            "clusters": m,
            "analytic_capture_prob": analytic_capture_prob(k, m, f),
            "empirical_captured_frac_mean": float(np.mean(emp)),
            "empirical_captured_frac_ci": float(
                1.96 * np.std(emp, ddof=1) / math.sqrt(seeds)),
            "expected_captured_clusters": float(np.mean(first_round_captured)),
            "max_captured_clusters": float(np.max(first_round_captured)),
        })
    return rows


def capture_study(seeds: int, rounds: int, k: int, base_seed: int) -> List[Dict]:
    """Compare the in-bound restriction against full captured-cluster behavior."""
    rows: List[Dict] = []
    for f in FRACTIONS:
        for capture in (False, True):
            acc_all, acc_in, complete, censored = [], [], [], []
            iso_in, iso_all = [], []
            for s in range(seeds):
                cfg = SimConfig(k=k, rounds=rounds, byz_frac=f,
                                model_capture=capture,
                                adversary=Adversary(kind="naive"),
                                profile=NetworkProfile(loss=0.02))
                sim = HZKASimulation(cfg, seed=base_seed + 9500 + s)
                hist = sim.run()
                tail = slice(rounds // 2, rounds)
                acc_all.append(np.mean([h.audit_accuracy for h in hist][tail]))
                acc_in.append(np.mean([h.accuracy_inbound for h in hist][tail]))
                complete.append(np.mean([h.round_complete for h in hist]))
                censored.append(np.mean([h.censored_clusters for h in hist]))
                iso = list(sim.isolation_round.values())
                n_byz = sum(1 for c in sim.committers if c.byzantine)
                iso_all.append(len(iso) / max(1, n_byz))
                iso_in.append(float(np.mean(iso)) if iso else float("nan"))
            rows.append({
                "byz_frac": f,
                "model_capture": int(capture),
                "steady_accuracy_all": float(np.mean(acc_all)),
                "steady_accuracy_inbound": float(np.mean(acc_in)),
                "round_complete_frac": float(np.mean(complete)),
                "mean_censored_clusters": float(np.mean(censored)),
                "byzantine_isolated_frac": float(np.mean(iso_all)),
                "mean_isolation_round": float(np.nanmean(iso_in)),
            })
    return rows


def epoch_healing(seeds: int, k: int, base_seed: int) -> List[Dict]:
    """Does epoch reassignment dissolve a captured cluster?"""
    rows: List[Dict] = []
    rounds = 260                      # spans two reassignment boundaries
    for f in (0.20, 0.30, 0.40):
        pre, post, isolated = [], [], []
        for s in range(seeds):
            cfg = SimConfig(k=k, rounds=rounds, byz_frac=f, model_capture=True,
                            adversary=Adversary(kind="naive"),
                            profile=NetworkProfile(loss=0.02))
            sim = HZKASimulation(cfg, seed=base_seed + 9700 + s)
            hist = sim.run()
            pre.append(np.mean([h.captured_clusters for h in hist[:99]]))
            post.append(np.mean([h.captured_clusters for h in hist[100:199]]))
            n_byz = sum(1 for c in sim.committers if c.byzantine)
            isolated.append(len(sim.isolation_round) / max(1, n_byz))
        rows.append({
            "byz_frac": f,
            "captured_epoch1_mean": float(np.mean(pre)),
            "captured_epoch2_mean": float(np.mean(post)),
            "byzantine_isolated_frac_260r": float(np.mean(isolated)),
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
    ap.add_argument("--seeds", type=int, default=30)
    ap.add_argument("--rounds", type=int, default=200)
    ap.add_argument("--k", type=int, default=100)
    ap.add_argument("--seed", type=int, default=20260822)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)

    occ = occupancy(args.seeds, args.k, args.seed)
    write_csv(os.path.join(OUT, "e9_bft_occupancy.csv"), occ)

    cap = capture_study(args.seeds, args.rounds, args.k, args.seed)
    write_csv(os.path.join(OUT, "e9_capture.csv"), cap)

    heal = epoch_healing(min(args.seeds, 15), args.k, args.seed)
    write_csv(os.path.join(OUT, "e9_epoch_healing.csv"), heal)

    with open(os.path.join(OUT, "e9_summary.json"), "w", encoding="utf-8") as fh:
        json.dump({"config": vars(args), "occupancy": occ,
                   "capture": cap, "epoch_healing": heal}, fh, indent=2)

    print("E9 complete.\n")
    print("Part A: clusters violating f_l < |C_l|/3 (k=%d, B=%d)" % (args.k, args.k // occ[0]["clusters"]))
    print("   f    analytic P[capture]  captured clusters (of %d)" % occ[0]["clusters"])
    for r in occ:
        print("  %.2f          %.4f            %.2f  (max %d)"
              % (r["byz_frac"], r["analytic_capture_prob"],
                 r["expected_captured_clusters"], int(r["max_captured_clusters"])))
    print("\nParts B and C: in-bound vs captured-cluster behavior")
    print("   f  capture | acc(all)  acc(in-bound)  round-complete  isolated")
    for r in cap:
        print("  %.2f    %d    |  %.4f      %.4f          %.4f      %.4f"
              % (r["byz_frac"], r["model_capture"], r["steady_accuracy_all"],
                 r["steady_accuracy_inbound"], r["round_complete_frac"],
                 r["byzantine_isolated_frac"]))
    print("\nEpoch healing (reassignment at round 100):")
    for r in heal:
        print("  f=%.2f captured epoch1 %.2f -> epoch2 %.2f, isolated %.3f"
              % (r["byz_frac"], r["captured_epoch1_mean"],
                 r["captured_epoch2_mean"], r["byzantine_isolated_frac_260r"]))


if __name__ == "__main__":
    main()
