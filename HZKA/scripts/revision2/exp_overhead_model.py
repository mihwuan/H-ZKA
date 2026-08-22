#!/usr/bin/env python3
"""Experiment E6: unified per-stage computation, storage, and communication.

Produces the accounting that backs the manuscript's unified complexity table:
per-round message count, bytes on the wire, on-chain storage growth, and
prover memory, for the flat per-chain audit pattern and for H-ZKA, over
k in {25, 50, 100, 150, 200}.

Artefact sizes are the ones used elsewhere in the manuscript: a Groth16
BN254 proof is 127 bytes as submitted, a state root or commitment is 32 bytes,
a signature is 65 bytes, and the presence bitmap is ceil(B_max/8) bytes per
cluster.  Prover memory uses the measured RAM profile of the padded circuit.

Outputs
-------
result/revision2/e6_overhead.csv
result/revision2/e6_summary.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
from typing import Dict, List

# Artefact sizes in bytes.
PROOF_B = 127
ROOT_B = 32
SIG_B = 65
PUBIN_B = 32
HEADER_B = 96          # round header: height, timestamp, slot vector digest

# Measured prover memory for the padded aggregation circuit (GiB per M
# constraints), from the artefact's RAM profile: 24 GiB at 8M constraints.
GIB_PER_MCONSTRAINT = 24.0 / 8.0
AGG_CONSTRAINTS_M = 20.0
CHAIN_CONSTRAINTS_M = 11.763593     # zkCross per-chain circuit


def per_round(k: int, b_max: int) -> Dict[str, float]:
    m = math.ceil(math.sqrt(k))
    b = k / float(m)

    # ---- flat baseline: every chain submits to the global audit chain
    flat_msgs = k
    flat_bytes = k * (PROOF_B + ROOT_B + SIG_B + PUBIN_B) + HEADER_B
    flat_verifications = k
    flat_storage = k * (ROOT_B + PROOF_B)
    flat_prover_gib = CHAIN_CONSTRAINTS_M * GIB_PER_MCONSTRAINT

    # ---- H-ZKA: chains -> cluster head, then heads -> global audit chain
    bitmap_b = math.ceil(b_max / 8.0)
    intra_msgs = k
    intra_bytes = k * (PROOF_B + ROOT_B + SIG_B)
    global_msgs = m
    global_bytes = m * (PROOF_B + ROOT_B + SIG_B + PUBIN_B + bitmap_b) + HEADER_B
    hzka_msgs = intra_msgs + global_msgs
    hzka_bytes = intra_bytes + global_bytes
    hzka_verifications = m
    hzka_storage = m * (ROOT_B + PROOF_B + bitmap_b)
    hzka_prover_gib = AGG_CONSTRAINTS_M * GIB_PER_MCONSTRAINT

    return {
        "k": k,
        "clusters": m,
        "avg_cluster_size": b,
        "flat_msgs": flat_msgs,
        "hzka_msgs": hzka_msgs,
        "flat_onchain_bytes": flat_bytes,
        "hzka_onchain_bytes": global_bytes,
        "hzka_total_bytes": hzka_bytes,
        "onchain_bytes_reduction": flat_bytes / float(global_bytes),
        "flat_verifications": flat_verifications,
        "hzka_verifications": hzka_verifications,
        "verification_reduction": flat_verifications / float(hzka_verifications),
        "flat_storage_bytes_per_round": flat_storage,
        "hzka_storage_bytes_per_round": hzka_storage,
        "storage_reduction": flat_storage / float(hzka_storage),
        "flat_storage_gib_per_year": flat_storage * (365 * 24 * 3600 / 120.0) / 2**30,
        "hzka_storage_gib_per_year": hzka_storage * (365 * 24 * 3600 / 120.0) / 2**30,
        "flat_prover_peak_gib": flat_prover_gib,
        "hzka_prover_peak_gib": hzka_prover_gib,
        "hzka_concurrent_prover_gib": hzka_prover_gib * m,
        "flat_concurrent_prover_gib": flat_prover_gib * k,
    }


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
    ap.add_argument("--b-max", type=int, default=15)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)

    rows = [per_round(k, args.b_max) for k in (25, 50, 100, 150, 200)]
    write_csv(os.path.join(OUT, "e6_overhead.csv"), rows)
    with open(os.path.join(OUT, "e6_summary.json"), "w", encoding="utf-8") as fh:
        json.dump({"config": vars(args),
                   "artefact_sizes_bytes": {
                       "proof": PROOF_B, "root": ROOT_B, "signature": SIG_B,
                       "public_input": PUBIN_B, "round_header": HEADER_B},
                   "prover_memory_gib_per_mconstraint": GIB_PER_MCONSTRAINT,
                   "rows": rows}, fh, indent=2)

    print("E6 complete.")
    for r in rows:
        print(f"  k={r['k']:>3} onchain {r['flat_onchain_bytes']:>7.0f} -> "
              f"{r['hzka_onchain_bytes']:>6.0f} B ({r['onchain_bytes_reduction']:.1f}x)  "
              f"storage/yr {r['flat_storage_gib_per_year']:.2f} -> "
              f"{r['hzka_storage_gib_per_year']:.2f} GiB  "
              f"prover peak {r['hzka_prover_peak_gib']:.0f} GiB")


OUT = os.path.join(os.path.dirname(__file__), "..", "..", "result", "revision2")

if __name__ == "__main__":
    main()
