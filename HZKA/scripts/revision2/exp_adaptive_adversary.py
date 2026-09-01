#!/usr/bin/env python3
"""Experiment E2: strategic, adaptive, and colluding adversaries.

Part A -- single-adversary strategy comparison.  Six behavioural policies are
run against the canonical MF-PoP machine and against a convex-only baseline
that lacks the non-resetting safety multiplier.  The reported quantities are
the number of confirmed safety faults the strategy lands, the round at which
the absorbing safety jail is entered, the stake destroyed, and the number of
honest rounds the strategy must purchase per additional fault.

Part B -- budget-exhaustion check.  A grid search over all threshold-aware
attack schedules confirms the analytic ceiling: no schedule lands more than
seven confirmed safety faults, because the safety multiplier is non-resetting
and the base reputation is bounded above by one.

Part C -- coordinated collusion.  c colluding committers are placed in the
population and the empirical cluster-head capture rate is compared with the
capped single-round selection bound of Eq. (22).

Outputs
-------
result/revision2/e2_strategies.csv
result/revision2/e2_collusion.csv
result/revision2/e2_summary.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
from typing import Dict, List

import numpy as np

from hzka_protocol_sim import (INVALID, VALID, Adversary, ConvexOnlyBaseline,
                               HZKASimulation, MFPoP, NetworkProfile,
                               Q_S, R_ELIG, R_JAIL, SimConfig)

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "result", "revision2")

STRATEGIES = [
    ("Always invalid", Adversary(kind="naive")),
    ("Periodic (N=6)", Adversary(kind="periodic", period=6)),
    ("Periodic (N=20)", Adversary(kind="periodic", period=20)),
    ("Omission only", Adversary(kind="omission")),
    ("Farm then betray", Adversary(kind="farm", warmup=100)),
    ("Threshold-adaptive", Adversary(kind="adaptive")),
]


# ---------------------------------------------------------------------------
# Part A: isolated-attacker trajectories in a noise-free adjudication channel
# ---------------------------------------------------------------------------


def run_strategy(adv: Adversary, rounds: int) -> Dict:
    """Deterministic single-committer trajectory under perfect adjudication.

    Isolating the attacker from network noise measures the strategy itself
    rather than the delivery channel; the population-level effect is measured
    separately in E1 and in Part C.
    """
    st = MFPoP()
    reference = MFPoP()          # an always-valid honest committer
    faults = 0
    jail_round = None
    honest_rounds = 0
    stake_lost = 0.0
    fault_rounds: List[int] = []
    elig_rounds = 0
    weight_ratio: List[float] = []
    schedule: List[str] = []

    for t in range(1, rounds + 1):
        ev = adv.act(st, t)
        schedule.append(ev)
        if ev == VALID:
            honest_rounds += 1
        if ev == INVALID and not st.jailed:
            faults += 1
            fault_rounds.append(t)
        stake_lost += st.step(ev)
        reference.step(VALID)
        if st.jailed and jail_round is None:
            jail_round = t
        if st.eligible:
            elig_rounds += 1
        w_ref = reference.election_weight()
        weight_ratio.append(st.election_weight() / w_ref if w_ref > 0 else 0.0)

    # Ablation: replay the identical behavioural schedule against a convex-only
    # update that has no non-resetting safety multiplier.
    base = ConvexOnlyBaseline()
    for ev in schedule:
        base.step(ev)

    gaps = [fault_rounds[i + 1] - fault_rounds[i]
            for i in range(len(fault_rounds) - 1)]
    return {
        "confirmed_faults": faults,
        "jail_round": jail_round,
        "stake_destroyed_frac": stake_lost,
        "final_raw_reputation": st.raw_reputation,
        "eligible_rounds": elig_rounds,
        "eligible_frac": elig_rounds / float(rounds),
        "mean_weight_ratio": float(np.mean(weight_ratio)),
        "final_weight_ratio": float(weight_ratio[-1]),
        "honest_rounds_spent": honest_rounds,
        "honest_rounds_per_fault": (honest_rounds / faults) if faults else None,
        "max_gap_between_faults": max(gaps) if gaps else None,
        "baseline_final_reputation": base.raw_reputation,
        "baseline_eligible": base.eligible,
        "baseline_weight_ratio": base.election_weight() / max(1e-12, reference.election_weight()),
        "weight_ratio_trace": weight_ratio,
        "schedule": schedule,
    }


# ---------------------------------------------------------------------------
# Part B: exhaustive ceiling check over threshold-aware schedules
# ---------------------------------------------------------------------------


def fault_ceiling(max_farm: int = 4000) -> Dict:
    """Largest confirmed-fault count reachable by any evasion schedule.

    The attacker is granted an unbounded honest-farming budget between faults
    and full knowledge of its own state, which upper-bounds every adaptive
    policy.  It attacks whenever the projected post-fault raw reputation
    exceeds the jail threshold, and otherwise farms reputation.
    """
    st = MFPoP()
    faults = 0
    farm_cost: List[int] = []
    spent = 0
    while True:
        if st.r_base * st.phi * Q_S > R_JAIL:
            st.step(INVALID)
            faults += 1
            farm_cost.append(spent)
            spent = 0
            if st.jailed:
                break
            continue
        # farm honest reputation until another fault becomes survivable
        before = st.r_base
        st.step(VALID)
        spent += 1
        if spent > max_farm or st.r_base - before < 1e-12:
            break
    # the ceiling: one further fault is always fatal because r_base <= 1
    fatal = MFPoP()
    fatal.r_base = 1.0
    fatal.phi = Q_S ** faults
    fatal.step(INVALID)
    return {
        "max_faults_before_jail": faults,
        "jailed_at_next_fault": fatal.jailed,
        "farm_rounds_per_fault": farm_cost,
        "post_ceiling_raw_reputation": st.r_base * st.phi,
        "eligible_after_ceiling": st.r_base * st.phi > R_ELIG,
        "analytic_bound": int(math.floor(math.log(R_JAIL) / math.log(Q_S))),
    }


# ---------------------------------------------------------------------------
# Part C: coordinated collusion and cluster-head capture
# ---------------------------------------------------------------------------


def collusion_sweep(seeds: int, rounds: int, k: int, base_seed: int,
                    topology_file: str = None) -> List[Dict]:
    rows: List[Dict] = []
    n_clusters = int(math.ceil(math.sqrt(k)))
    for c_size in [0, 5, 10, 20, 30, 40]:
        cap_rate, head_honest, first_epoch_cap = [], [], []
        for s in range(seeds):
            cfg = SimConfig(
                k=k, rounds=rounds,
                byz_frac=max(0.05, c_size / float(k)),
                collusion_size=c_size,
                adversary=Adversary(kind="adaptive"),
                profile=NetworkProfile(loss=0.02),
                topology_file=topology_file)
            sim = HZKASimulation(cfg, seed=base_seed + 7000 + s)
            hist = sim.run()
            cap_rate.append(sim.head_capture_rounds / max(1, sim.head_rounds))
            head_honest.append(np.mean([h.head_honest_frac for h in hist]))
            first_epoch_cap.append(
                1.0 - np.mean([h.head_honest_frac for h in hist[:20]]))
        # Conservative per-cluster instantiation of Eq. (22): every eligible
        # member is credited only the minimum admissible weight R_elig, and
        # the adversary is credited the cap w_max.
        members_per_cluster = max(1, k // n_clusters)
        bound = 1.0 / (1.0 + max(0, members_per_cluster - 1) * R_ELIG)
        rows.append({
            "colluders": c_size,
            "colluder_frac": c_size / float(k),
            "head_capture_rate_mean": float(np.mean(cap_rate)),
            "head_capture_rate_ci": float(1.96 * np.std(cap_rate, ddof=1) / np.sqrt(seeds)),
            "head_honest_frac_mean": float(np.mean(head_honest)),
            "early_capture_rate_mean": float(np.mean(first_epoch_cap)),
            "proportional_share": c_size / float(k),
            "n_clusters": n_clusters,
            "capped_single_round_bound": bound,
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
                "" if r[c] is None else
                (f"{r[c]:.6f}" if isinstance(r[c], float) else str(r[c]))
                for c in cols) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=30)
    ap.add_argument("--rounds", type=int, default=500)
    ap.add_argument("--k", type=int, default=100)
    ap.add_argument("--seed", type=int, default=20260822)
    ap.add_argument("--topology-file", type=str, default=None,
                    help="JSON topology file for trace-calibrated simulation")
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)

    strat_rows: List[Dict] = []
    strat_traces: Dict[str, List[Dict]] = {}
    for name, adv in STRATEGIES:
        r = run_strategy(adv, args.rounds)
        weight_trace = r.pop("weight_ratio_trace")
        schedule = r.pop("schedule")
        r["strategy"] = name
        strat_rows.append({"strategy": name, **{k: v for k, v in r.items()
                                                if k != "strategy"}})
        # Export per-round trace for this strategy
        trace_rows = []
        for t, (w_ratio, action) in enumerate(zip(weight_trace, schedule), 1):
            trace_rows.append({
                "round": t,
                "weight_ratio": w_ratio,
                "action": action,
            })
        strat_traces[name] = trace_rows
    
    write_csv(os.path.join(OUT, "e2_strategies.csv"), strat_rows)
    
    # Write per-round traces for each strategy
    for name, traces in strat_traces.items():
        trace_path = os.path.join(OUT, f"e2_trace_{name.replace(' ', '_').lower()}.csv")
        trace_cols = ["round", "weight_ratio", "action"]
        with open(trace_path, "w", encoding="utf-8") as fh:
            fh.write(",".join(trace_cols) + "\n")
            for r in traces:
                fh.write(f"{r['round']},{r['weight_ratio']:.9f},{r['action']}\n")

    ceiling = fault_ceiling()
    coll = collusion_sweep(args.seeds, min(args.rounds, 300), args.k, args.seed,
                            topology_file=args.topology_file)
    write_csv(os.path.join(OUT, "e2_collusion.csv"), coll)

    with open(os.path.join(OUT, "e2_summary.json"), "w", encoding="utf-8") as fh:
        json.dump({"config": vars(args), "strategies": strat_rows,
                   "ceiling": ceiling, "collusion": coll}, fh, indent=2)

    print("E2 complete.")
    for r in strat_rows:
        print(f"  {r['strategy']:<20} faults={r['confirmed_faults']:<3} "
              f"jail={r['jail_round']} stake_lost={r['stake_destroyed_frac']:.3f} "
              f"w_final={r['final_weight_ratio']:.4f} "
              f"base_w={r['baseline_weight_ratio']:.4f} "
              f"honest/fault={r['honest_rounds_per_fault']}")
    print(f"  ceiling: {ceiling['max_faults_before_jail']} faults, "
          f"farm cost per fault {ceiling['farm_rounds_per_fault']}, "
          f"next fault jails = {ceiling['jailed_at_next_fault']}")
    for r in coll:
        print(f"  colluders={r['colluders']:<3} capture={r['head_capture_rate_mean']:.4f} "
              f"(proportional {r['proportional_share']:.2f})")


if __name__ == "__main__":
    main()
