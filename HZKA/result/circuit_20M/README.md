# 20M Aggregation-Circuit Artifact (Matched Toolchain)

This directory stores the measured 20M-constraint run that must match the manuscript toolchain and interface.

## Required match conditions

1. Statement: verify B_max = 15 inner Groth16 proofs and per-slot state transition.
2. Public inputs: exactly 3 (cluster commitment, cluster id, round).
3. Security: BN254, 128-bit target.
4. Toolchain: Rust/Arkworks with feature parallel.
5. Host: AsusL40 class node (Xeon Gold 6538Y+, 16 vCPU, 200 GiB), with >=128 GiB free before run.

## Run layout

Create one subfolder per run id, for example:

- result/circuit_20M/20260824T120000Z/

Each run folder should include at minimum:

- manifest.pre_run.txt
- environment.txt
- build_agg/agg.r1cs
- build_agg/agg_pk.bin
- build_agg/agg_vk.bin
- artifact.sha256
- deps.lock.txt
- witness.bin
- witness.time
- prove_1.time
- prove_2.time
- prove_3.time
- proof_1.bin
- proof_2.bin
- proof_3.bin
- public_1.json
- verify.log
- manifest.row.csv

## Recommended execution helper

Use script:

- scripts/revision2/run_20m_matched_toolchain.sh

## Manuscript update checklist after measured run

1. Table 8: switch 20M row from Predicted to Measured.
2. Table 19: replace interval row by measured mean and CI from 3 runs.
3. Section 7.9 / Table 21: convert to model-validation table and add per-model error vs measured.
4. Section 7.5.1 / Tables 14-15: recompute worker, memory, critical path, and latency parity k with measured S_agg.
5. Table 42 and Section 8.2: recompute +17% and +29% overheads.
6. Abstract, Section 9 item (1), Section 10: remove prediction language.
