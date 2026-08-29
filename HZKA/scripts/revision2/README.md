# H-ZKA protocol and cost experiments (E1–E10)

Seeded discrete-round simulations of the H-ZKA audit layer, plus exact cost
models derived from the EVM gas schedule and the measured circuit profile.
Together these produce Tables 14–17 and 23–41 of the manuscript.

Three kinds of evidence live here and the manuscript labels each one:

* **Simulated** (E1–E5, E9, E10 part B): seeded discrete-round protocol
  simulation. Not a hardware measurement.
* **Analytical, exact** (E6, E7, E8, E10 part A): derived from protocol
  constants such as the EVM gas schedule, or from measured service times. No
  fitting.
* **Measured** results (proving benchmarks, coordination latency, contract
  bookkeeping) live elsewhere in `result/` and are unchanged by this
  directory.

## What is simulated

`hzka_protocol_sim.py` implements:

* the canonical MF-PoP transition (manuscript Eqs. 8–19) at fixed-point parity
  with `contracts/audit_chain/ReputationRegistry.sol`;
* the capacitated *k*-medoid cluster-formation objective under
  `D_ab(η) = η·RTT_ab + (1−η)·(1−ρ_ab)` (Eq. 20–21);
* capped reputation-weighted VRF cluster-head election (Eq. 21) with the jail
  gate;
* epoch reassignment every `E_epoch = 100` rounds;
* an audit-layer link model calibrated to the same `tc/netem` profile used for
  the measured coordination results: 50 ms intra-region, 200 ms inter-region,
  500 ms intercontinental base latency, lognormal jitter (σ = 0.25), 0–5%
  packet loss, ≤ 2 retransmissions inside a 3 s round deadline;
* node churn, contiguous network partitions, and cluster-head crash/failover.

## Experiments

| Script | Manuscript | Question |
|---|---|---|
| `exp_byzantine_churn.py` | Tables 23, 26, 27 | Recovery under Byzantine ratio, churn, outage length, latency, loss; empirical location of the omission-ineligibility boundary |
| `exp_adaptive_adversary.py` | Tables 28–29 | Six adversarial strategies, the strategy-independent fault ceiling, coordinated collusion and cluster-head capture |
| `exp_clustering_ablation.py` | Tables 30–31 | η sweep and five-policy clustering ablation |
| `exp_leakage.py` | Tables 32–33 | Metadata leakage under matched fixed-shape baselines, with prior and cluster-size sensitivity |
| `exp_fault_recovery.py` | Table 34 | Cluster-head failure: blast radius, burst amplification, failover cost |
| `exp_overhead_model.py` | Tables 37–38 | Per-stage computation, communication, storage, and prover memory |
| `exp_onchain_cost.py` | Tables 16–17 | Exact on-chain verification gas from the EVM schedule, for both public-input interfaces |
| `exp_prover_pipeline.py` | Tables 14–15, 41 | Two-stage prover accounting: k inner proofs plus M aggregations, on one system boundary |
| `exp_bft_bound.py` | Tables 24–25 | How often the per-cluster BFT condition fails, and what a captured cluster can do |
| `exp_config_sensitivity.py` | Tables 35–36 | Cluster-count trade-off and bursty-arrival sensitivity |

## Reproducing

```bash
cd HZKA/scripts/revision2
bash run_all.sh                 # full configuration used in the manuscript
SEEDS=5 ROUNDS=100 bash run_all.sh   # fast smoke run
```

Requirements: Python ≥ 3.9, NumPy ≥ 1.24, SciPy (only `exp_leakage.py` uses it).
No plotting library is needed; results are written as CSV and JSON to
`../../result/revision2/` and the manuscript renders its own figures.

Everything is deterministic. The base seed is `20260822`; re-running with the
same `--seed` reproduces every published number bit for bit. Each script also
writes its full parameter set into its `*_summary.json`.

## The 20M circuit was executed

`result/circuit_20M/` holds the measured run: 20,014,400 constraints, three
public inputs (commitment interface), real Poseidon state-transition and
commitment-binding gadgets, AsusL40 with 16 Rayon threads, Rust/Arkworks with
`parallel`.

| Quantity | Measured |
| --- | --- |
| Proving time (3 runs) | 120.89, 126.69, 120.03 s → **122.54 ± 9.00 s** |
| Peak resident memory | 46.58 GiB (2.33 GiB per million constraints) |
| Setup time | 105.1 s |
| Proving key | 4.28 GB |
| Verification | 4.0 ms, VALID |

**Read the timings carefully.** `/usr/bin/time -v` wall clock for these runs was
1h13m, 5h23m, and 1h16m. That is *not* proving time: it is dominated by
deserializing the 4.28 GB proving key on a contended shared host. The prover's
own reported figure, with the key resident, is the 120–127 s above, and it is
the number the capacity model needs. `parse_20m_results.py` originally reported
the wall clock and has been corrected. The cold-start cost is a real deployment
constraint in its own right: an aggregation worker must be a long-lived process.

Against the three predictions: linear 90.2 s (error +35.8%), quasilinear
108.3 s (**+13.1%**, closest), power law 79.3 s (+54.5%). The union interval's
upper bound of 122.5 s was accurate to 0.04 s. The quasilinear form, which was
argued for on FFT/MSM grounds, was right.

One scope limit: the constraint load of the fifteen inner Groth16 verifications
is represented by structurally equivalent constraints rather than a full
non-native pairing implementation. The circuit is size- and interface-matched,
which is sound for timing and memory, but it does not demonstrate that a
complete recursive verifier of this size has been written.

## Corrections in this revision

Four results changed materially after an Associate Editor review identified
internal inconsistencies. They are listed here because the earlier numbers were
published in this repository.

1. **Prover accounting was not symmetric.** The earlier model compared H-ZKA's
   `M` aggregation jobs against the baseline's `k` per-chain jobs. H-ZKA needs
   the same `k` inner proofs *and* `M` aggregations. Corrected, H-ZKA requires
   **17% more** prover workers at k=100 (55 vs 47), not 83% fewer.
   See `exp_prover_pipeline.py`.

2. **The gas figure used a mock verifier.** `deploy_global_audit.cjs` calls
   `enableMockVerifier()`, so the recorded 324,145 gas per cluster excludes
   Groth16 verification entirely and cannot support the earlier 13.8x
   end-to-end claim. Verification cost is now derived exactly from the EVM gas
   schedule in `exp_onchain_cost.py`, giving 10.0x at k=100.

3. **The O(√k) claim depended on an interface not stated in Algorithm 1.**
   Exposing every member root as a public input makes the scalar-multiplication
   and calldata terms Θ(k). Publishing one constant-size cluster commitment
   restores O(√k) in every term. `exp_onchain_cost.py` quantifies both.

4. **The leakage baseline was not matched.** The flat arm was given a
   variable-size circuit, which Groth16 does not permit. With matched
   fixed-shape baselines the reduction is 3.0x in the worst tested
   configuration rather than 56.9x, and it comes from the commitment interface
   rather than from aggregation. See `exp_leakage.py`.

## Headline results

* **Fault ceiling.** No strategy, adaptive or patient, lands more than six
  confirmed safety faults before the absorbing jail; the seventh always
  triggers it. The strongest evader forfeits 46.9% of stake and must perform
  158 consecutive honest rounds to buy its sixth fault, after which its
  election weight is capped at 1.6% of an honest committer's.
* **Byzantine recovery, conditioned.** Within the per-cluster BFT condition,
  audit accuracy stays above 0.995 at every global ratio and every faulty
  committer is isolated. The condition is the binding constraint: it already
  fails for 1.8 of 10 clusters at a 20% global Byzantine ratio, and a captured
  cluster can censor adjudication for a whole epoch.
* **Liveness/safety separation.** Across 900 churn runs and 720 partition runs,
  including 120-round outages, zero honest committers were jailed and zero
  honest stake was slashed. Election ineligibility begins at exactly 69
  consecutive missed rounds for a committer at the default `r_0 = 0.5`, and 76
  for one that has accumulated 40 valid rounds; one valid submission restores
  it in every case.
* **Collusion.** A coalition holding 40% of the population captures 2.41% of
  cluster-head slots, a factor of 16.6 below its population share.
* **Clustering.** A balanced random partition is dominated on every axis. At
  η = 0.75 the k-medoid partition cuts intra-cluster RTT by 52.5% and
  transaction cut by 22.6% against random assignment.
* **Leakage.** Under matched fixed-shape baselines, the constant-size cluster
  commitment reduces leakage by 3.0x in the worst tested configuration
  (sparse activity, small clusters) and by three orders of magnitude when
  activity is dense. Hierarchical aggregation with per-chain public inputs
  leaks exactly as much as flat publication, so the benefit is an interface
  property, not an aggregation property.
* **Failure concentration.** Cluster-head crashes leave the *mean* number of
  stalled chains unchanged versus the flat baseline but raise its standard
  deviation by 3.3×. With three failover attempts per cluster inside a 120 s
  round budget, 1.3% of rounds are lost at a 10% crash rate and 8.5% at 20%.

## Output files

```
result/revision2/
  e1_byzantine_recovery.csv   e1_churn_grid.csv   e1_partition.csv   e1_summary.json
  e2_strategies.csv           e2_collusion.csv                       e2_summary.json
  e3_eta_sweep.csv            e3_policy_comparison.csv  e3_end_to_end.csv  e3_summary.json
  e4_leakage.csv              e4_sensitivity.csv                     e4_summary.json
  e5_fault_recovery.csv                                              e5_summary.json
  e6_overhead.csv                                                    e6_summary.json
  e7_onchain_cost.csv         e7_tx_breakdown.csv                    e7_summary.json
  e8_pipeline.csv                                                    e8_summary.json
  e9_bft_occupancy.csv        e9_capture.csv      e9_epoch_healing.csv  e9_summary.json
  e10_cluster_config.csv      e10_burstiness.csv                     e10_summary.json
```

## Table manifest

| Manuscript table | Produced by |
| --- | --- |
| 14, 15, 41 | `exp_prover_pipeline.py` → `e8_pipeline.csv` |
| 16, 17 | `exp_onchain_cost.py` → `e7_*.csv` |
| 23, 26, 27 | `exp_byzantine_churn.py` → `e1_*.csv` |
| 24, 25 | `exp_bft_bound.py` → `e9_*.csv` |
| 28, 29 | `exp_adaptive_adversary.py` → `e2_*.csv` |
| 30, 31 | `exp_clustering_ablation.py` → `e3_*.csv` |
| 32, 33 | `exp_leakage.py` → `e4_*.csv` |
| 34 | `exp_fault_recovery.py` → `e5_*.csv` |
| 35, 36 | `exp_config_sensitivity.py` → `e10_*.csv` |
| 37, 38 | `exp_overhead_model.py` → `e6_overhead.csv` |
