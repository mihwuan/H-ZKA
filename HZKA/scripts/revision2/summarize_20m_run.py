#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import os
import re
from typing import Dict, List


ELAPSED_PAT = re.compile(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\):\s*(.+)")
RSS_PAT = re.compile(r"Maximum resident set size \(kbytes\):\s*(\d+)")


def parse_elapsed_to_seconds(raw: str) -> float:
    txt = raw.strip()
    parts = txt.split(":")
    if len(parts) == 2:
        m, s = parts
        return int(m) * 60 + float(s)
    if len(parts) == 3:
        h, m, s = parts
        return int(h) * 3600 + int(m) * 60 + float(s)
    raise ValueError(f"Unrecognized elapsed format: {raw}")


def parse_time_v(path: str) -> Dict[str, float]:
    elapsed = None
    rss = None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = ELAPSED_PAT.search(line)
            if m:
                elapsed = parse_elapsed_to_seconds(m.group(1))
            r = RSS_PAT.search(line)
            if r:
                rss = int(r.group(1))
    if elapsed is None or rss is None:
        raise ValueError(f"Could not parse elapsed/rss in {path}")
    return {"elapsed_s": elapsed, "max_rss_kib": rss}


def mean(xs: List[float]) -> float:
    return sum(xs) / len(xs)


def stdev_sample(xs: List[float]) -> float:
    if len(xs) < 2:
        return 0.0
    mu = mean(xs)
    var = sum((x - mu) ** 2 for x in xs) / (len(xs) - 1)
    return math.sqrt(var)


def ci95_half_width(xs: List[float]) -> float:
    # n=3, t_{0.975,2} = 4.30265272975
    if len(xs) < 2:
        return 0.0
    t = 4.30265272975 if len(xs) == 3 else 1.96
    return t * stdev_sample(xs) / math.sqrt(len(xs))


def main() -> None:
    ap = argparse.ArgumentParser(description="Summarize one 20M run directory")
    ap.add_argument("--run-dir", required=True)
    ap.add_argument("--pred-linear", type=float, default=90.2)
    ap.add_argument("--pred-quasilinear", type=float, default=108.3)
    ap.add_argument("--pred-low", type=float, default=54.6)
    ap.add_argument("--pred-high", type=float, default=122.5)
    args = ap.parse_args()

    run_dir = args.run_dir
    witness = parse_time_v(os.path.join(run_dir, "witness.time"))
    p1 = parse_time_v(os.path.join(run_dir, "prove_1.time"))
    p2 = parse_time_v(os.path.join(run_dir, "prove_2.time"))
    p3 = parse_time_v(os.path.join(run_dir, "prove_3.time"))

    prove_times = [p1["elapsed_s"], p2["elapsed_s"], p3["elapsed_s"]]
    prove_mean = mean(prove_times)
    prove_ci95 = ci95_half_width(prove_times)

    model_errors = {
        "linear_abs_error_s": abs(args.pred_linear - prove_mean),
        "quasilinear_abs_error_s": abs(args.pred_quasilinear - prove_mean),
        "interval_low_abs_error_s": abs(args.pred_low - prove_mean),
        "interval_high_abs_error_s": abs(args.pred_high - prove_mean),
    }

    out = {
        "run_dir": run_dir,
        "witness": witness,
        "prove_runs": [p1, p2, p3],
        "prove_mean_s": prove_mean,
        "prove_ci95_half_width_s": prove_ci95,
        "prove_min_s": min(prove_times),
        "prove_max_s": max(prove_times),
        "model_errors_vs_measured": model_errors,
    }

    out_path = os.path.join(run_dir, "summary_20m.json")
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2)

    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
