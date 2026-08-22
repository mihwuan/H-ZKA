#!/usr/bin/env python3
"""Experiment E3: clustering-policy ablation.

Part A -- eta sweep.  The capacitated k-medoid partition of Eq. (21) is
computed for eta in {0.00, 0.25, 0.50, 0.75, 1.00} and scored on mean
intra-cluster RTT, transaction-cut ratio, size imbalance, padding ratio,
epoch-to-epoch reassignment churn, and simulated round coordination latency.

Part B -- policy comparison.  The tuned k-medoid partition is compared with a
balanced random partition, a pure RTT partition, and a pure flow-correlation
partition at fixed k.

Part C -- topology sensitivity.  The sweep is repeated for three
geography/flow alignment regimes so that the selected eta is not an artefact
of one synthetic topology.

Outputs
-------
result/revision2/e3_eta_sweep.csv
result/revision2/e3_policy_comparison.csv
result/revision2/e3_summary.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
from typing import Dict, List

import numpy as np

from hzka_protocol_sim import (Adversary, HZKASimulation, NetworkProfile,
                               SimConfig, cluster_metrics, kmedoid_partition,
                               make_topology, random_partition,
                               reassignment_churn)

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "result", "revision2")
ETAS = [0.00, 0.25, 0.50, 0.75, 1.00]


def coordination_ms(labels: np.ndarray, topo, n_clusters: int) -> float:
    """Two-phase coordination latency for a partition, medoid-rooted."""
    per_cluster = []
    heads = []
    for c in range(n_clusters):
        members = np.where(labels == c)[0]
        if members.size == 0:
            continue
        sub = topo.rtt_ms[np.ix_(members, members)]
        head = int(members[int(np.argmin(sub.sum(axis=1)))])
        heads.append(head)
        hops = [topo.rtt_ms[j, head] for j in members if j != head]
        per_cluster.append(max(hops) if hops else 0.0)
    intra = max(per_cluster) if per_cluster else 0.0
    glob = max((topo.rtt_ms[h, heads[0]] for h in heads), default=0.0)
    return float(intra + glob)


def score_partition(labels, topo, n_clusters, b_max) -> Dict[str, float]:
    m = cluster_metrics(labels, topo, b_max)
    m["coordination_ms"] = coordination_ms(labels, topo, n_clusters)
    return m


def eta_sweep(seeds: int, k: int, b_max: int, alignment: float,
              base_seed: int, epochs: int = 5) -> List[Dict]:
    n_clusters = int(math.ceil(math.sqrt(k)))
    rows: List[Dict] = []
    for eta in ETAS:
        acc: Dict[str, List[float]] = {}
        churn_vals: List[float] = []
        for s in range(seeds):
            rng = np.random.default_rng(base_seed + s)
            topo = make_topology(k, rng, community_alignment=alignment)
            dist = topo.distance(eta)
            prev = None
            for _ in range(epochs):
                labels = kmedoid_partition(dist, n_clusters, rng, capacity=b_max)
                if prev is not None:
                    churn_vals.append(reassignment_churn(prev, labels))
                prev = labels
            m = score_partition(prev, topo, n_clusters, b_max)
            for key, val in m.items():
                acc.setdefault(key, []).append(val)
        row = {"eta": eta, "alignment": alignment, "k": k}
        for key, vals in acc.items():
            row[f"{key}_mean"] = float(np.mean(vals))
            row[f"{key}_ci"] = float(1.96 * np.std(vals, ddof=1) / np.sqrt(len(vals)))
        row["epoch_churn_mean"] = float(np.mean(churn_vals)) if churn_vals else 0.0
        rows.append(row)
    return rows


def policy_comparison(seeds: int, k: int, b_max: int, alignment: float,
                      base_seed: int) -> List[Dict]:
    n_clusters = int(math.ceil(math.sqrt(k)))
    policies = {
        "Random (balanced)": None,
        "RTT only (eta=1.00)": 1.00,
        "Flow only (eta=0.00)": 0.00,
        "H-ZKA k-medoid (eta=0.50)": 0.50,
        "H-ZKA k-medoid (eta=0.75)": 0.75,
    }
    rows: List[Dict] = []
    for name, eta in policies.items():
        acc: Dict[str, List[float]] = {}
        for s in range(seeds):
            rng = np.random.default_rng(base_seed + 300 + s)
            topo = make_topology(k, rng, community_alignment=alignment)
            if eta is None:
                labels = random_partition(k, n_clusters, rng)
            else:
                labels = kmedoid_partition(topo.distance(eta), n_clusters,
                                           rng, capacity=b_max)
            for key, val in score_partition(labels, topo, n_clusters, b_max).items():
                acc.setdefault(key, []).append(val)
        row = {"policy": name, "k": k}
        for key, vals in acc.items():
            row[f"{key}_mean"] = float(np.mean(vals))
            row[f"{key}_ci"] = float(1.96 * np.std(vals, ddof=1) / np.sqrt(len(vals)))
        rows.append(row)
    return rows


def end_to_end_effect(seeds: int, k: int, base_seed: int) -> List[Dict]:
    """Effect of eta on the simulated audit round, including MF-PoP dynamics."""
    rows: List[Dict] = []
    for eta in ETAS:
        coord, acc = [], []
        for s in range(seeds):
            cfg = SimConfig(k=k, rounds=100, byz_frac=0.20, eta=eta,
                            adversary=Adversary(kind="naive"),
                            profile=NetworkProfile(loss=0.02))
            sim = HZKASimulation(cfg, seed=base_seed + 900 + s)
            hist = sim.run()
            coord.append(np.mean([h.coordination_ms for h in hist]))
            acc.append(np.mean([h.audit_accuracy for h in hist[50:]]))
        rows.append({
            "eta": eta,
            "round_coordination_ms_mean": float(np.mean(coord)),
            "round_coordination_ms_ci": float(1.96 * np.std(coord, ddof=1) / np.sqrt(seeds)),
            "steady_accuracy_mean": float(np.mean(acc)),
        })
    return rows


def write_csv(path: str, rows: List[Dict]) -> None:
    if not rows:
        return
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
    ap.add_argument("--k", type=int, default=100)
    ap.add_argument("--b-max", type=int, default=15)
    ap.add_argument("--seed", type=int, default=20260822)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)

    sweep_rows: List[Dict] = []
    for alignment in (0.0, 0.5, 1.0):
        sweep_rows.extend(eta_sweep(args.seeds, args.k, args.b_max,
                                    alignment, args.seed))
    write_csv(os.path.join(OUT, "e3_eta_sweep.csv"), sweep_rows)

    pol = policy_comparison(args.seeds, args.k, args.b_max, 0.5, args.seed)
    write_csv(os.path.join(OUT, "e3_policy_comparison.csv"), pol)

    e2e = end_to_end_effect(min(args.seeds, 15), args.k, args.seed)
    write_csv(os.path.join(OUT, "e3_end_to_end.csv"), e2e)

    with open(os.path.join(OUT, "e3_summary.json"), "w", encoding="utf-8") as fh:
        json.dump({"config": vars(args), "eta_sweep": sweep_rows,
                   "policies": pol, "end_to_end": e2e}, fh, indent=2)

    print("E3 complete.")
    for r in sweep_rows:
        if r["alignment"] != 0.5:
            continue
        print(f"  eta={r['eta']:.2f} rtt={r['mean_intra_rtt_ms_mean']:7.1f}ms "
              f"cut={r['tx_cut_ratio_mean']:.3f} gini={r['size_gini_mean']:.3f} "
              f"pad={r['padding_ratio_mean']:.3f} churn={r['epoch_churn_mean']:.3f} "
              f"coord={r['coordination_ms_mean']:7.1f}ms")
    print("  policies:")
    for r in pol:
        print(f"    {r['policy']:<28} rtt={r['mean_intra_rtt_ms_mean']:7.1f} "
              f"cut={r['tx_cut_ratio_mean']:.3f} coord={r['coordination_ms_mean']:7.1f}")


if __name__ == "__main__":
    main()
