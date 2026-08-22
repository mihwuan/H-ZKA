# H-ZKA second-revision protocol experiments (E1–E6)

Seeded discrete-round simulations of the H-ZKA audit layer, plus the byte-exact
communication and storage accounting. These back the simulated tables in
Sections 7.12–7.19 of the manuscript.

They are **protocol simulations**, not hardware measurements. The proving,
verification, gas, and coordination numbers reported elsewhere in the paper
come from the Azure/HPC testbed and the Solidity contracts and are unchanged by
anything in this directory.

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
| `exp_byzantine_churn.py` | §7.13, Tables 12–14 | Recovery under Byzantine ratio, churn, outage length, latency, loss; empirical location of the omission-ineligibility boundary |
| `exp_adaptive_adversary.py` | §7.14, Tables 15–16 | Six adversarial strategies, the strategy-independent fault ceiling, coordinated collusion and cluster-head capture |
| `exp_clustering_ablation.py` | §7.15, Tables 17–18 | η sweep and five-policy clustering ablation |
| `exp_leakage.py` | §7.16, Table 19 | Mutual information and adversary advantage for audit-layer timing/size metadata |
| `exp_fault_recovery.py` | §7.17, Table 20 | Cluster-head failure: blast radius, burst amplification, failover cost |
| `exp_overhead_model.py` | §7.18, Tables 21–22 | Per-stage computation, communication, storage, and prover memory |

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

## Headline results

* **Fault ceiling.** No strategy, adaptive or patient, lands more than six
  confirmed safety faults before the absorbing jail; the seventh always
  triggers it. The strongest evader forfeits 46.9% of stake and must perform
  158 consecutive honest rounds to buy its sixth fault, after which its
  election weight is capped at 1.6% of an honest committer's.
* **Byzantine recovery.** Honest control of cluster heads returns to 1.000 by
  round 10 at every Byzantine ratio up to 50%, over 30 seeds.
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
* **Leakage.** Aggregating by chain cluster reduces measured metadata leakage
  from 0.7074 to 0.0124 bits per chain-round, a factor of 56.9; fixed-shape
  padding accounts for a further 21.7% of the residual.
* **Failure concentration.** Cluster-head crashes leave the *mean* number of
  stalled chains unchanged versus the flat baseline but raise its standard
  deviation by 3.4×. This is the honest structural cost of hierarchy and is
  reported as such.

## Output files

```
result/revision2/
  e1_byzantine_recovery.csv   e1_churn_grid.csv   e1_partition.csv   e1_summary.json
  e2_strategies.csv           e2_collusion.csv                       e2_summary.json
  e3_eta_sweep.csv            e3_policy_comparison.csv  e3_end_to_end.csv  e3_summary.json
  e4_leakage.csv                                                     e4_summary.json
  e5_fault_recovery.csv                                              e5_summary.json
  e6_overhead.csv                                                    e6_summary.json
```
