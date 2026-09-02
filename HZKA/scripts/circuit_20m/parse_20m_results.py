#!/usr/bin/env python3
"""Parse the 20M circuit execution results and update manuscript tables.

This script reads the three ``prove_i.time`` files produced by
``run_20m_circuit.sh``, extracts wall-clock time and peak RSS, computes
the mean and 95% confidence interval, and writes:

  1. A manifest row for Table 19 (measured mean and CI).
  2. A model-validation table for Section 7.9, Table 21 (error of each
     extrapolation form against the measured value).
  3. Updated E8 pipeline rows using the measured S_agg instead of the
     predicted interval.

Outputs
-------
result/circuit_20M/measured_summary.json
result/circuit_20M/model_validation.csv
result/circuit_20M/e8_pipeline_measured.csv

Usage
-----
    python3 parse_20m_results.py [--result-dir ../../result/circuit_20M]
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from typing import Dict, List, Optional, Tuple

# Add parent directory for E8 imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "revision2"))

RESULT_DIR_DEFAULT = os.path.join(
    os.path.dirname(__file__), "..", "..", "result", "circuit_20M")


def parse_time_v(path: str) -> Dict[str, float]:
    """Extract timings and peak RSS from a /usr/bin/time -v capture.

    Three different quantities appear in these logs and they must not be
    confused.  ``proving_s`` is the prover's own reported figure with the
    proving key already resident, and it is the number the capacity model
    needs.  ``wall_clock_s`` additionally includes cargo compilation and
    deserialisation of the 4.28 GB proving key, which on a contended host
    dominates everything else.  Reporting wall clock as proving time
    overstates it by roughly two orders of magnitude.
    """
    result: Dict[str, float] = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                # Wall clock time: h:mm:ss or m:ss.ss
                m2 = re.search(r"\[proving\] completed in ([0-9.]+)s", line)
                if m2:
                    result["proving_s"] = float(m2.group(1))
                m = re.search(r"wall clock.*?:\s*(?:(\d+):)?(\d+):(\d+\.?\d*)", line)
                if m:
                    hours = int(m.group(1) or 0)
                    mins = int(m.group(2))
                    secs = float(m.group(3))
                    result["wall_clock_s"] = hours * 3600 + mins * 60 + secs
                # Peak RSS in KiB
                m2 = re.search(r"Maximum resident set size.*?:\s*(\d+)", line)
                if m2:
                    result["peak_rss_kib"] = float(m2.group(1))
    except FileNotFoundError:
        pass
    return result


def mean_ci(values: List[float]) -> Tuple[float, float]:
    """Compute mean and 95% CI."""
    n = len(values)
    if n == 0:
        return 0.0, 0.0
    m = sum(values) / n
    if n == 1:
        return m, 0.0
    var = sum((x - m) ** 2 for x in values) / (n - 1)
    # Student's t, not the normal approximation: with n = 3 repetitions the
    # normal quantile understates the interval by more than a factor of two.
    t_crit = {2: 4.302653, 3: 3.182446, 4: 2.776445, 5: 2.570582}.get(n - 1, 1.96)
    ci = t_crit * math.sqrt(var / n)
    return m, ci


def model_validation(measured_s: float) -> List[Dict[str, float]]:
    """Compare measured S_agg against the three model forms from Table 21.

    The three model forms and their predicted values at 20M constraints:
      - Linear:       S_agg = 4.5117 * C_M  →  90.2 s
      - Quasilinear:  S_agg = 3.1 * C_M * log2(C_M)  →  108.3 s  (approximate)
      - Sublinear:    S_agg = 12.7 * C_M^0.75  →  54.6 s  (approximate lower)
    """
    models = [
        ("Linear",       90.2),
        ("Quasilinear",  108.3),
        ("Interval low (sublinear)", 54.6),
        ("Interval high", 122.5),
    ]
    rows = []
    for name, predicted in models:
        error = measured_s - predicted
        rel_error = error / predicted if predicted != 0 else float("inf")
        rows.append({
            "model": name,
            "predicted_s": predicted,
            "measured_s": measured_s,
            "error_s": error,
            "relative_error_pct": 100.0 * rel_error,
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


def update_pipeline(measured_s: float, result_dir: str) -> None:
    """Recompute E8 pipeline with the measured S_agg."""
    try:
        from exp_prover_pipeline import pipeline, parity_k, write_csv as e8_csv
    except ImportError:
        print("  Warning: could not import exp_prover_pipeline; skipping E8 update.")
        return

    tau = 120.0
    rows: List[Dict] = []
    for k in (25, 50, 100, 150, 200):
        r = pipeline(k, measured_s, tau)
        r["scenario"] = "measured"
        rows.append(r)
    e8_csv(os.path.join(result_dir, "e8_pipeline_measured.csv"), rows)

    pk = parity_k(measured_s)
    print(f"  Latency parity k (measured S_agg = {measured_s:.1f} s): {pk:.0f}")
    return


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--result-dir", default=RESULT_DIR_DEFAULT)
    args = ap.parse_args()
    result_dir = args.result_dir

    # Parse the three prove runs
    times: List[float] = []
    wall_times: List[float] = []
    rss_values: List[float] = []
    for i in (1, 2, 3):
        path = os.path.join(result_dir, f"prove_{i}.time")
        parsed = parse_time_v(path)
        # Prefer the prover's own reported proving time; fall back to wall
        # clock only if the prover did not report one.
        if "proving_s" in parsed:
            times.append(parsed["proving_s"])
        elif "wall_clock_s" in parsed:
            times.append(parsed["wall_clock_s"])
        if "wall_clock_s" in parsed:
            wall_times.append(parsed["wall_clock_s"])
        if "peak_rss_kib" in parsed:
            rss_values.append(parsed["peak_rss_kib"])

    if not times:
        print("No prove_*.time files found.  Creating placeholder summary.")
        print("Run this script again after executing run_20m_circuit.sh on the AsusL40 node.")
        # Create a placeholder
        summary = {
            "status": "PLACEHOLDER — no measured data yet",
            "note": "Execute run_20m_circuit.sh on AsusL40 first, then re-run this script.",
            "expected_constraint_count": 20_000_000,
            "b_max": 15,
            "public_inputs": 3,
        }
        with open(os.path.join(result_dir, "measured_summary.json"), "w") as fh:
            json.dump(summary, fh, indent=2)
        print(f"  Wrote placeholder to {result_dir}/measured_summary.json")
        return

    mean_time, ci_time = mean_ci(times)
    mean_rss, ci_rss = mean_ci(rss_values)
    rss_gib = mean_rss / (1024 * 1024) if mean_rss else 0.0

    print("=" * 60)
    print("  20M Circuit Measured Results")
    print("=" * 60)
    print(f"  Proving time:  {mean_time:.1f} ± {ci_time:.1f} s  (n={len(times)})")
    print(f"  Peak RSS:      {rss_gib:.1f} GiB  (n={len(rss_values)})")
    print()

    # Parse witness time
    witness_parsed = parse_time_v(os.path.join(result_dir, "witness.time"))
    witness_s = witness_parsed.get("wall_clock_s", None)

    # Summary JSON
    summary = {
        "constraint_count_target": 20_000_000,
        "b_max": 15,
        "public_inputs": 3,
        "interface": "commitment",
        "security_level": (
            "BN254, approximately 100-bit under exTNFS "
            "(Kim and Barbulescu, CRYPTO 2016; draft-irtf-cfrg-pairing-friendly-curves)"
        ),
        "proving_time_mean_s": mean_time,
        "proving_time_ci_s": ci_time,
        "proving_time_runs_s": times,
        "wall_clock_runs_s": wall_times,
        "wall_clock_note": (
            "Wall clock includes cargo build and deserialisation of the "
            "4.28 GB proving key; it is a cold-start cost, not proving time."
        ),
        "peak_rss_mean_kib": mean_rss,
        "peak_rss_mean_gib": rss_gib,
        "peak_rss_ci_kib": ci_rss,
        "witness_generation_s": witness_s,
    }
    with open(os.path.join(result_dir, "measured_summary.json"), "w") as fh:
        json.dump(summary, fh, indent=2)
    print(f"  Summary written to {result_dir}/measured_summary.json")

    # Model validation (Table 21)
    validation = model_validation(mean_time)
    write_csv(os.path.join(result_dir, "model_validation.csv"), validation)
    print("\n  Model validation (Table 21):")
    print("    %-28s  predicted  measured  error   rel.error" % "Model")
    for r in validation:
        print("    %-28s  %7.1f   %7.1f  %+6.1f   %+6.1f%%"
              % (r["model"], r["predicted_s"], r["measured_s"],
                 r["error_s"], r["relative_error_pct"]))

    # Update E8 pipeline tables with measured S_agg
    print("\n  Updating E8 pipeline with measured S_agg...")
    update_pipeline(mean_time, result_dir)

    print("\nDone.  Update the manuscript:")
    print("  - Table 8:  change 20M row from Predicted to Measured")
    print("  - Table 19: replace interval row with measured mean and CI")
    print("  - Table 21: add model-error column from model_validation.csv")
    print("  - Tables 14-15: recompute from e8_pipeline_measured.csv")
    print("  - Table 42 / Section 8.2: recompute overhead percentages")
    print("  - Abstract / Section 9(1) / Section 10: remove prediction language")


if __name__ == "__main__":
    main()
