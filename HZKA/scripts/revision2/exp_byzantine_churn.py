#!/usr/bin/env python3
"""Experiment E1: stochastic robustness under Byzantine ratio, churn, and delay.

Replaces the previous closed-form recovery table with a seeded stochastic
sweep over

  * Byzantine population fraction f in {0.00, 0.10, 0.20, 0.30, 0.40, 0.50};
  * per-round node churn in {0.00, 0.01, 0.05, 0.10};
  * heterogeneous one-way base latency in {50, 200, 500} ms with 0-5% loss;
  * static and dynamic (round-varying) workload.

Outputs
-------
result/revision2/e1_byzantine_recovery.csv   accuracy trajectory per f
result/revision2/e1_churn_grid.csv           churn x latency grid
result/revision2/e1_summary.json             headline numbers for the paper

Usage
-----
    python3 exp_byzantine_churn.py --seeds 30 --rounds 200
"""

from __future__ import annotations

import argparse
import json
import os
from typing import Dict, List

import numpy as np

from hzka_protocol_sim import (Adversary, HZKASimulation, NetworkProfile,
                               SimConfig)

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "result", "revision2")
REPORT_ROUNDS = (1, 5, 10, 20, 50, 100)


def mean_ci(x: np.ndarray, axis: int = 0):
    m = np.mean(x, axis=axis)
    n = x.shape[axis]
    ci = 1.96 * np.std(x, axis=axis, ddof=1) / np.sqrt(n) if n > 1 else np.zeros_like(m)
    return m, ci


def sweep_byzantine(seeds: int, rounds: int, k: int, base_seed: int) -> Dict:
    fractions = [0.0, 0.10, 0.20, 0.30, 0.40, 0.50]
    rows: List[Dict] = []
    summary: Dict[str, Dict] = {}

    for f in fractions:
        acc = np.zeros((seeds, rounds))
        head = np.zeros((seeds, rounds))
        wshare = np.zeros((seeds, rounds))
        jail_h = np.zeros((seeds, rounds))
        iso_rounds: List[float] = []
        faults: List[float] = []

        for s in range(seeds):
            cfg = SimConfig(k=k, rounds=rounds, byz_frac=f,
                            adversary=Adversary(kind="naive"),
                            profile=NetworkProfile(loss=0.02))
            sim = HZKASimulation(cfg, seed=base_seed + s)
            hist = sim.run()
            acc[s] = [h.audit_accuracy for h in hist]
            head[s] = [h.head_honest_frac for h in hist]
            wshare[s] = [1.0 - h.byz_weight_share for h in hist]
            jail_h[s] = [h.jailed_honest for h in hist]
            if sim.isolation_round:
                iso_rounds.extend(sim.isolation_round.values())
            faults.extend(c.state.v for c in sim.committers if c.byzantine)

        m_acc, ci_acc = mean_ci(acc)
        m_head, ci_head = mean_ci(head)
        m_ws, ci_ws = mean_ci(wshare)
        for t in range(rounds):
            rows.append({
                "byz_frac": f, "round": t + 1,
                "accuracy_mean": m_acc[t], "accuracy_ci": ci_acc[t],
                "head_honest_mean": m_head[t], "head_honest_ci": ci_head[t],
                "honest_weight_share_mean": m_ws[t],
                "honest_weight_share_ci": ci_ws[t],
            })
        summary[f"{f:.2f}"] = {
            "accuracy_at": {str(t): [float(m_acc[t - 1]), float(ci_acc[t - 1])]
                            for t in REPORT_ROUNDS if t <= rounds},
            "head_honest_at": {str(t): [float(m_head[t - 1]), float(ci_head[t - 1])]
                               for t in REPORT_ROUNDS if t <= rounds},
            "honest_weight_share_at": {str(t): [float(m_ws[t - 1]), float(ci_ws[t - 1])]
                                       for t in REPORT_ROUNDS if t <= rounds},
            "mean_isolation_round": float(np.mean(iso_rounds)) if iso_rounds else None,
            "max_isolation_round": float(np.max(iso_rounds)) if iso_rounds else None,
            "mean_confirmed_faults_per_byz": float(np.mean(faults)) if faults else 0.0,
            "max_confirmed_faults_per_byz": float(np.max(faults)) if faults else 0.0,
            "honest_jailed_total": float(jail_h[:, -1].sum()),
        }
    return {"rows": rows, "summary": summary}


def sweep_churn(seeds: int, rounds: int, k: int, base_seed: int) -> Dict:
    """Churn and heterogeneous-delay grid.

    ``rejoin`` controls the mean outage length: a node that leaves returns
    after 1/rejoin rounds in expectation, so 0.30/0.10/0.02 correspond to
    roughly 3, 10, and 50 consecutive missed rounds.
    """
    churns = [0.0, 0.01, 0.05, 0.10]
    rejoins = [0.30, 0.10, 0.02]
    latencies = [("50", 50.0, 200.0, 500.0, 0.0),
                 ("200", 200.0, 300.0, 500.0, 0.025),
                 ("500", 500.0, 500.0, 800.0, 0.05)]
    rows: List[Dict] = []

    for churn in churns:
        for rejoin in (rejoins if churn > 0 else [0.30]):
            for tag, intra, inter, glob, loss in latencies:
                acc, elig, jail_h, recov = [], [], [], []
                offline, complete, coord = [], [], []
                for s in range(seeds):
                    prof = NetworkProfile(intra_region_ms=intra,
                                          inter_region_ms=inter,
                                          global_ms=glob, loss=loss)
                    cfg = SimConfig(k=k, rounds=rounds, byz_frac=0.20,
                                    churn_rate=churn, rejoin_rate=rejoin,
                                    adversary=Adversary(kind="naive"),
                                    profile=prof, workload_dynamic=True)
                    sim = HZKASimulation(cfg, seed=base_seed + 1000 + s)
                    hist = sim.run()
                    tail = slice(rounds // 2, rounds)
                    n_honest = sum(1 for c in sim.committers if not c.byzantine)
                    acc.append(np.mean([h.audit_accuracy for h in hist][tail]))
                    elig.append(np.mean(
                        [n_honest - h.honest_eligible for h in hist][tail]))
                    jail_h.append(hist[-1].jailed_honest)
                    offline.append(np.mean([h.offline for h in hist][tail]))
                    complete.append(np.mean(
                        [h.valid_events / float(k) for h in hist][tail]))
                    coord.append(np.mean([h.coordination_ms for h in hist][tail]))
                    traj = np.array([h.audit_accuracy for h in hist])
                    target = 0.99 * traj[tail].mean()
                    idx = np.where(traj >= target)[0]
                    recov.append(float(idx[0] + 1) if idx.size else float(rounds))
                rows.append({
                    "churn_rate": churn,
                    "rejoin_rate": rejoin,
                    "mean_outage_rounds": (1.0 / rejoin) if churn > 0 else 0.0,
                    "latency_ms": tag, "loss": loss,
                    "steady_accuracy_mean": float(np.mean(acc)),
                    "steady_accuracy_ci": float(1.96 * np.std(acc, ddof=1) / np.sqrt(seeds)),
                    "round_completeness_mean": float(np.mean(complete)),
                    "round_completeness_ci": float(1.96 * np.std(complete, ddof=1) / np.sqrt(seeds)),
                    "honest_ineligible_mean": float(np.mean(elig)),
                    "honest_jailed_total": float(np.sum(jail_h)),
                    "mean_offline_nodes": float(np.mean(offline)),
                    "coordination_ms_mean": float(np.mean(coord)),
                    "recovery_round_mean": float(np.mean(recov)),
                })
    return {"rows": rows}


def partition_study(seeds: int, rounds: int, k: int, base_seed: int) -> Dict:
    """Contiguous-outage study of the omission-ineligibility boundary.

    A fifth of the chains is isolated for a fixed window and then healed.  Two
    regimes are reported.  ``fresh`` partitions from round 1, so the affected
    committers are still at the default initialisation r_0 = 0.5, which is the
    setting of the 69-round analytic bound.  ``established`` first lets the
    committers accumulate reputation for 40 valid rounds, which raises the
    omission tolerance.  Neither regime may slash stake or trigger the
    absorbing safety jail.
    """
    rows: List[Dict] = []
    regimes = (("fresh", 1), ("established", 41))
    windows = (60, 65, 68, 69, 70, 75, 76, 80, 82, 83, 90, 120)
    for regime, start in regimes:
        for window in windows:
            if start + window + 5 > rounds:
                continue
            lost, regain, jailed, slashed = [], [], [], []
            for s in range(seeds):
                cfg = SimConfig(k=k, rounds=rounds, byz_frac=0.20,
                                partition_frac=0.20,
                                partition_start=start,
                                partition_end=start + window,
                                adversary=Adversary(kind="naive"),
                                profile=NetworkProfile(loss=0.0,
                                                       unresolved_rate=0.0))
                sim = HZKASimulation(cfg, seed=base_seed + 3000 + s)
                hist = sim.run()
                n_honest = sum(1 for c in sim.committers if not c.byzantine)
                # Last fully partitioned round is (start + window - 1).
                lost.append(n_honest - hist[start + window - 2].honest_eligible)
                # Rounds after healing until every honest committer is eligible.
                r = None
                for t in range(start + window - 1, rounds):
                    if hist[t].honest_eligible >= n_honest:
                        r = t - (start + window - 2)
                        break
                regain.append(float(r) if r is not None else float("nan"))
                jailed.append(hist[-1].jailed_honest)
                slashed.append(sum(1.0 - c.state.stake for c in sim.committers
                                   if not c.byzantine))
            rows.append({
                "regime": regime,
                "outage_rounds": window,
                "honest_ineligible_at_heal": float(np.mean(lost)),
                "honest_ineligible_frac": float(np.mean(lost)) / (0.20 * k),
                "rounds_to_regain_eligibility": float(np.nanmean(regain)),
                "honest_jailed_total": float(np.sum(jailed)),
                "honest_stake_slashed_total": float(np.sum(slashed)),
            })
    return {"rows": rows}


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
    ap.add_argument("--rounds", type=int, default=200)
    ap.add_argument("--k", type=int, default=100)
    ap.add_argument("--seed", type=int, default=20260822)
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)

    byz = sweep_byzantine(args.seeds, args.rounds, args.k, args.seed)
    write_csv(os.path.join(OUT, "e1_byzantine_recovery.csv"), byz["rows"])

    churn = sweep_churn(args.seeds, args.rounds, args.k, args.seed)
    write_csv(os.path.join(OUT, "e1_churn_grid.csv"), churn["rows"])

    part = partition_study(args.seeds, args.rounds, args.k, args.seed)
    write_csv(os.path.join(OUT, "e1_partition.csv"), part["rows"])

    with open(os.path.join(OUT, "e1_summary.json"), "w", encoding="utf-8") as fh:
        json.dump({
            "config": {"seeds": args.seeds, "rounds": args.rounds,
                       "k": args.k, "base_seed": args.seed},
            "byzantine": byz["summary"],
            "churn_grid": churn["rows"],
            "partition": part["rows"],
        }, fh, indent=2)

    print("E1 complete.")
    for f, s in byz["summary"].items():
        a10 = s["accuracy_at"].get("10", [float("nan")])[0]
        print(f"  f={f}: acc@1={s['accuracy_at']['1'][0]:.4f} "
              f"acc@10={a10:.4f} maxIso={s['max_isolation_round']} "
              f"maxFaults={s['max_confirmed_faults_per_byz']:.0f} "
              f"honestJailed={s['honest_jailed_total']:.0f}")
    print("  partition study:")
    for r in part["rows"]:
        print(f"    {r['regime']:<12} outage={r['outage_rounds']:>3}r ineligible="
              f"{r['honest_ineligible_at_heal']:.1f} "
              f"regain={r['rounds_to_regain_eligibility']:.2f}r "
              f"jailed={r['honest_jailed_total']:.0f} "
              f"slashed={r['honest_stake_slashed_total']:.3f}")


if __name__ == "__main__":
    main()
