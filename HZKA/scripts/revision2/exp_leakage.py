#!/usr/bin/env python3
"""Experiment E4: quantitative audit-layer side-channel leakage.

Zero knowledge hides the private witness relative to the public statement.  It
does not bound what a passive observer of the audit layer learns from
*metadata*: submission timing, artefact size, and the presence bitmap.  This
experiment measures that residual channel empirically instead of asserting it
qualitatively.

Threat model
------------
A passive global observer records, for every audit round, the public audit-layer
transcript.  The secret is the per-chain workload class
S in {low, medium, high} of an ordinary chain in that round.  The observer's
goal is to infer S for a named chain.

Observation models
------------------
``flat``      one proof per chain (the zkCross audit pattern).  The per-chain
              circuit size grows with the transaction batch, so submission
              latency and artefact size are functions of that chain's own
              workload.
``hzka-var``  hierarchical aggregation *without* fixed-shape padding: the
              cluster head submits one proof whose cost tracks the number of
              real member proofs and their aggregate volume.
``hzka``      the deployed H-ZKA configuration: a Groth16 circuit compiled for
              the fixed capacity B_max, with unused slots filled by dummy
              proofs.  Proving cost is constant in the slot occupancy; only
              witness assembly retains a bounded dependence on real data.

Metrics
-------
* empirical mutual information I(S ; O) in bits, plug-in estimator with the
  Miller-Madow bias correction;
* the adversary's balanced accuracy from a maximum-a-posteriori classifier
  fitted on a disjoint training split;
* the advantage over the majority-class prior.

Outputs
-------
result/revision2/e4_leakage.csv
result/revision2/e4_summary.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
from typing import Dict, List, Tuple

import numpy as np

OUT = os.path.join(os.path.dirname(__file__), "..", "..", "result", "revision2")

# Calibration constants taken from the manuscript's measured records.
SEC_PER_MCONSTRAINT = 4.567686      # fitted prover regression, Eq. (39)
CHAIN_CIRCUIT_BASE_M = 1.20         # constant part of the per-chain circuit
CHAIN_CIRCUIT_PER_TX_M = 0.1176     # marginal cost per transaction, in millions
AGG_FIXED_M = 20.0                  # padded recursive circuit, 20M constraints
WITNESS_SEC_PER_TX = 0.004          # witness assembly, retained under padding
TIMING_NOISE_SD = 0.35              # observation noise, seconds
N_BINS = 12

CLASSES = (0, 1, 2)                 # low, medium, high
CLASS_MULT = (0.5, 1.0, 2.0)
CLASS_PRIOR = (0.45, 0.35, 0.20)


def sample_workloads(rng: np.random.Generator, rounds: int, k: int
                     ) -> Tuple[np.ndarray, np.ndarray]:
    """Return (secret class, transaction count) arrays of shape (rounds, k)."""
    base = rng.uniform(20.0, 80.0, size=k)         # heterogeneous chain sizes
    cls = rng.choice(CLASSES, size=(rounds, k), p=CLASS_PRIOR)
    mult = np.array(CLASS_MULT)[cls]
    tx = base[None, :] * mult * rng.lognormal(0.0, 0.18, size=(rounds, k))
    return cls, tx


def observe(model: str, tx: np.ndarray, labels: np.ndarray, b_max: int,
            rng: np.random.Generator) -> np.ndarray:
    """Return the observable assigned to each (round, chain) pair."""
    rounds, k = tx.shape
    noise = rng.normal(0.0, TIMING_NOISE_SD, size=(rounds, k))

    if model == "flat":
        constraints_m = CHAIN_CIRCUIT_BASE_M + CHAIN_CIRCUIT_PER_TX_M * tx
        return SEC_PER_MCONSTRAINT * constraints_m + noise

    n_clusters = int(labels.max()) + 1
    cluster_tx = np.zeros((rounds, n_clusters))
    for c in range(n_clusters):
        members = np.where(labels == c)[0]
        cluster_tx[:, c] = tx[:, members].sum(axis=1)
    sizes = np.array([(labels == c).sum() for c in range(n_clusters)])

    if model == "hzka-var":
        # A variable-shape aggregation circuit is recompiled per round, so its
        # constraint count tracks both the live occupancy and the real batch
        # carried by the member chains.
        ref_tx = float(np.median(cluster_tx))
        occupancy = sizes[None, :] / float(b_max)
        constraints_m = AGG_FIXED_M * occupancy * (cluster_tx / max(ref_tx, 1e-9))
        obs_cluster = (SEC_PER_MCONSTRAINT * constraints_m
                       + WITNESS_SEC_PER_TX * cluster_tx)
    elif model == "hzka":
        # fixed-shape padded circuit: proving cost independent of occupancy
        obs_cluster = (SEC_PER_MCONSTRAINT * AGG_FIXED_M
                       + WITNESS_SEC_PER_TX * cluster_tx)
    else:
        raise ValueError(model)

    obs = np.zeros((rounds, k))
    for c in range(n_clusters):
        members = np.where(labels == c)[0]
        obs[:, members] = obs_cluster[:, c][:, None]
    return obs + noise


def discretize(train: np.ndarray, test: np.ndarray, n_bins: int
               ) -> Tuple[np.ndarray, np.ndarray]:
    """Equal-frequency binning with edges fitted on the training split only."""
    qs = np.linspace(0.0, 100.0, n_bins + 1)[1:-1]
    edges = np.percentile(train, qs)
    edges = np.unique(edges)
    return np.digitize(train, edges), np.digitize(test, edges)


def mutual_information_bits(s: np.ndarray, o: np.ndarray) -> float:
    """Plug-in mutual information with the Miller-Madow bias correction."""
    n = s.size
    s_vals = np.unique(s)
    o_vals = np.unique(o)
    joint = np.zeros((s_vals.size, o_vals.size))
    s_idx = {v: i for i, v in enumerate(s_vals)}
    o_idx = {v: i for i, v in enumerate(o_vals)}
    for a, b in zip(s, o):
        joint[s_idx[a], o_idx[b]] += 1.0
    joint /= n
    ps = joint.sum(axis=1, keepdims=True)
    po = joint.sum(axis=0, keepdims=True)
    with np.errstate(divide="ignore", invalid="ignore"):
        term = joint * np.log2(joint / (ps * po))
    mi = float(np.nansum(term))
    # Miller-Madow: (|S|-1)(|O|-1) / (2 n ln 2)
    support = np.count_nonzero(joint)
    df = max(0, support - s_vals.size - o_vals.size + 1)
    mi -= df / (2.0 * n * math.log(2.0))
    return max(0.0, mi)


def map_balanced_accuracy(s_tr: np.ndarray, o_tr: np.ndarray,
                          s_te: np.ndarray, o_te: np.ndarray) -> float:
    """Balanced accuracy of a MAP classifier fitted on the training split."""
    s_vals = np.unique(s_tr)
    o_vals = np.unique(np.concatenate([o_tr, o_te]))
    counts = np.ones((s_vals.size, o_vals.size))       # Laplace smoothing
    s_idx = {v: i for i, v in enumerate(s_vals)}
    o_idx = {v: i for i, v in enumerate(o_vals)}
    for a, b in zip(s_tr, o_tr):
        counts[s_idx[a], o_idx[b]] += 1.0
    posterior = counts / counts.sum(axis=0, keepdims=True)
    pred_for_bin = s_vals[np.argmax(posterior, axis=0)]
    pred = np.array([pred_for_bin[o_idx[b]] for b in o_te])

    recalls = []
    for v in s_vals:
        mask = s_te == v
        if mask.sum() == 0:
            continue
        recalls.append(float((pred[mask] == v).mean()))
    return float(np.mean(recalls)) if recalls else 0.0


def run(seeds: int, rounds: int, k: int, b_max: int, base_seed: int) -> List[Dict]:
    from hzka_protocol_sim import kmedoid_partition, make_topology

    n_clusters = int(math.ceil(math.sqrt(k)))
    models = ["flat", "hzka-var", "hzka"]
    acc: Dict[str, Dict[str, List[float]]] = {m: {"mi": [], "bacc": []} for m in models}

    for s in range(seeds):
        rng = np.random.default_rng(base_seed + s)
        topo = make_topology(k, rng, community_alignment=0.5)
        labels = kmedoid_partition(topo.distance(0.75), n_clusters, rng,
                                   capacity=b_max)
        cls, tx = sample_workloads(rng, rounds, k)
        split = rounds // 2
        for m in models:
            obs = observe(m, tx, labels, b_max, rng)
            o_tr_raw, o_te_raw = obs[:split].ravel(), obs[split:].ravel()
            s_tr, s_te = cls[:split].ravel(), cls[split:].ravel()
            o_tr, o_te = discretize(o_tr_raw, o_te_raw, N_BINS)
            acc[m]["mi"].append(mutual_information_bits(s_te, o_te))
            acc[m]["bacc"].append(map_balanced_accuracy(s_tr, o_tr, s_te, o_te))

    h_s = -sum(p * math.log2(p) for p in CLASS_PRIOR)
    rows: List[Dict] = []
    for m in models:
        mi = np.array(acc[m]["mi"])
        ba = np.array(acc[m]["bacc"])
        rows.append({
            "model": m,
            "mi_bits_mean": float(mi.mean()),
            "mi_bits_ci": float(1.96 * mi.std(ddof=1) / math.sqrt(seeds)),
            "mi_frac_of_entropy": float(mi.mean() / h_s),
            "balanced_accuracy_mean": float(ba.mean()),
            "balanced_accuracy_ci": float(1.96 * ba.std(ddof=1) / math.sqrt(seeds)),
            "advantage_over_chance": float(ba.mean() - 1.0 / len(CLASSES)),
            "anonymity_set": 1 if m == "flat" else b_max,
            "secret_entropy_bits": h_s,
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
    ap.add_argument("--rounds", type=int, default=400)
    ap.add_argument("--k", type=int, default=100)
    ap.add_argument("--b-max", type=int, default=15)
    ap.add_argument("--seed", type=int, default=20260822)
    args = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)

    rows = run(args.seeds, args.rounds, args.k, args.b_max, args.seed)
    write_csv(os.path.join(OUT, "e4_leakage.csv"), rows)
    with open(os.path.join(OUT, "e4_summary.json"), "w", encoding="utf-8") as fh:
        json.dump({"config": vars(args), "rows": rows,
                   "observation_model": {
                       "sec_per_mconstraint": SEC_PER_MCONSTRAINT,
                       "chain_circuit_base_m": CHAIN_CIRCUIT_BASE_M,
                       "chain_circuit_per_tx_m": CHAIN_CIRCUIT_PER_TX_M,
                       "agg_fixed_m": AGG_FIXED_M,
                       "witness_sec_per_tx": WITNESS_SEC_PER_TX,
                       "timing_noise_sd": TIMING_NOISE_SD,
                       "bins": N_BINS}}, fh, indent=2)

    print("E4 complete.  Secret entropy = %.3f bits" % rows[0]["secret_entropy_bits"])
    for r in rows:
        print(f"  {r['model']:<9} MI={r['mi_bits_mean']:.4f}+-{r['mi_bits_ci']:.4f} bits "
              f"({100*r['mi_frac_of_entropy']:.1f}% of H(S))  "
              f"bal.acc={r['balanced_accuracy_mean']:.4f} "
              f"adv={r['advantage_over_chance']:+.4f}")


if __name__ == "__main__":
    main()
