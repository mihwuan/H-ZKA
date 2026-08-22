#!/usr/bin/env python3
"""Experiment E8: two-stage prover accounting for the audit pipeline.

Why this exists
---------------
The previous capacity model compared H-ZKA's M aggregate-proof jobs against the
flat baseline's k per-chain jobs.  That is not a symmetric comparison.
Algorithm 1 requires every chain in a cluster to supply an individual proof
pi_j *before* the cluster head can produce pi_agg, so H-ZKA pays the same k
inner proofs as the flat baseline and then adds M recursive aggregations.

This script rebuilds the accounting as an explicit two-stage pipeline and
recomputes worker counts, vCPU, memory, and critical-path latency on the same
system boundary for both systems.

System boundary
---------------
Stage 1  per-chain proving of Lambda_Psi.  Required by both systems.
Stage 2  intra-cluster recursive aggregation of Lambda_agg.  H-ZKA only.
Stage 3  on-chain verification.  Costed separately in E7.

Service times
-------------
S_psi   55.8 s   measured baseline per-chain proof service time
S_agg   predicted; the union interval across three model forms is
        [54.6, 122.5] s, with 90.2 s (linear) and 108.3 s (quasilinear) as
        the two point values carried in the manuscript.

Outputs
-------
result/revision2/e8_pipeline.csv
result/revision2/e8_summary.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
from typing import Dict, List

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "result", "revision2")

S_PSI = 55.8                    # measured, per-chain circuit
GIB_PER_MCONSTRAINT = 24.0 / 8.0
PSI_CONSTRAINTS_M = 11.763593
AGG_CONSTRAINTS_M = 20.0
MEM_PSI = PSI_CONSTRAINTS_M * GIB_PER_MCONSTRAINT      # 35.3 GiB
MEM_AGG = AGG_CONSTRAINTS_M * GIB_PER_MCONSTRAINT      # 60.0 GiB
VCPU_PER_WORKER = 16

# Measured network coordination (Table 13): total for the flat pattern and
# aggregation + global audit for H-ZKA.
L_FLAT = {25: 10.00, 50: 20.00, 100: 40.00, 150: 60.00, 200: 80.00}
L_HZKA = {25: 1.65, 50: 2.64, 100: 3.31, 150: 4.29, 200: 4.96}


def workers(load_seconds: float, tau: float) -> int:
    """Minimum servers for strict queue stability at cadence tau."""
    return math.floor(load_seconds / tau) + 1


def pipeline(k: int, s_agg: float, tau: float) -> Dict[str, float]:
    m = math.ceil(math.sqrt(k))

    # --- stage loads per round
    inner_load = k * S_PSI                 # both systems
    agg_load = m * s_agg                   # H-ZKA only

    c_flat = workers(inner_load, tau)
    c_inner = workers(inner_load, tau)     # identical stage, identical cost
    c_agg = workers(agg_load, tau)
    c_hzka = c_inner + c_agg

    mem_flat = c_flat * MEM_PSI
    mem_hzka = c_inner * MEM_PSI + c_agg * MEM_AGG

    # --- critical path under full provisioning: inner proof, then aggregation,
    #     then network coordination.  The aggregation cannot start until every
    #     member proof is available.
    t_flat = S_PSI + L_FLAT[k]
    t_hzka = S_PSI + s_agg + L_HZKA[k]

    return {
        "k": k, "clusters": m, "s_agg": s_agg, "tau": tau,
        "inner_jobs": k, "agg_jobs": m,
        "flat_workers": c_flat,
        "hzka_inner_workers": c_inner,
        "hzka_agg_workers": c_agg,
        "hzka_total_workers": c_hzka,
        "worker_ratio_hzka_over_flat": c_hzka / c_flat,
        "flat_vcpu": c_flat * VCPU_PER_WORKER,
        "hzka_vcpu": c_hzka * VCPU_PER_WORKER,
        "flat_memory_gib": mem_flat,
        "hzka_memory_gib": mem_hzka,
        "memory_ratio_hzka_over_flat": mem_hzka / mem_flat,
        "flat_critical_path_s": t_flat,
        "hzka_critical_path_s": t_hzka,
        "latency_ratio_hzka_over_flat": t_hzka / t_flat,
        # incremental framing: what the aggregation layer alone costs
        "incremental_workers": c_agg,
        "incremental_memory_gib": c_agg * MEM_AGG,
    }


def parity_k(s_agg: float) -> float:
    """k at which the two critical paths meet.

    L_flat(k) = 0.4 k exactly.  L_hzka is fitted from the measured points.
    """
    xs = sorted(L_HZKA)
    n = len(xs)
    sx = sum(xs); sy = sum(L_HZKA[x] for x in xs)
    sxx = sum(x * x for x in xs); sxy = sum(x * L_HZKA[x] for x in xs)
    slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    intercept = (sy - slope * sx) / n
    # 0.4k - (slope*k + intercept) = s_agg
    return (s_agg + intercept) / (0.4 - slope)


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
    ap.add_argument("--tau", type=float, default=120.0)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)

    scenarios = [("linear point", 90.2), ("quasilinear point", 108.3),
                 ("interval low", 54.6), ("interval high", 122.5)]
    rows: List[Dict] = []
    for label, s_agg in scenarios:
        for k in (25, 50, 100, 150, 200):
            r = pipeline(k, s_agg, args.tau)
            r["scenario"] = label
            rows.append(r)
    write_csv(os.path.join(OUT, "e8_pipeline.csv"), rows)

    parity = {label: parity_k(s) for label, s in scenarios}
    with open(os.path.join(OUT, "e8_summary.json"), "w", encoding="utf-8") as fh:
        json.dump({"config": vars(args),
                   "service_times": {"S_psi_measured_s": S_PSI,
                                     "scenarios": dict(scenarios)},
                   "memory_gib": {"per_chain_prover": MEM_PSI,
                                  "cluster_head": MEM_AGG},
                   "rows": rows,
                   "latency_parity_k": parity}, fh, indent=2)

    print("E8 complete.  Two-stage prover accounting, tau = %.0f s.\n" % args.tau)
    for label, s_agg in scenarios[:2]:
        print("Scenario: %s (S_agg = %.1f s)" % (label, s_agg))
        print("   k    M | flat W | inner W + agg W = H-ZKA W | ratio |"
              " mem flat  mem H-ZKA  ratio | T_flat  T_HZKA  ratio")
        for r in [x for x in rows if x["scenario"] == label]:
            print("  %3d %4d | %6d | %7d + %5d = %9d | %5.2fx | %8.0f %10.0f %6.2fx |"
                  " %6.1f %7.1f %6.2fx"
                  % (r["k"], r["clusters"], r["flat_workers"],
                     r["hzka_inner_workers"], r["hzka_agg_workers"],
                     r["hzka_total_workers"], r["worker_ratio_hzka_over_flat"],
                     r["flat_memory_gib"], r["hzka_memory_gib"],
                     r["memory_ratio_hzka_over_flat"],
                     r["flat_critical_path_s"], r["hzka_critical_path_s"],
                     r["latency_ratio_hzka_over_flat"]))
        print()
    print("Latency parity k (critical paths meet):")
    for label, kk in parity.items():
        print("  %-18s k = %.0f" % (label, kk))


if __name__ == "__main__":
    main()
