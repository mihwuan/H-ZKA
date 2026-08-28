// H-ZKA aggregation circuit library.
//
// This module defines the aggregation circuit Λ_agg that verifies B_max
// inner Groth16 proofs and a state transition, producing a constant-size
// commitment (Poseidon hash) as the public output.
//
// The circuit matches Algorithm 1 in the manuscript:
//   Public inputs:  (clusterCommitment, clusterId, round)
//   Private inputs: B_max inner proofs + their public inputs
//
// The `parallel` feature enables Rayon-based multi-threaded proving.

pub mod aggregation;
pub mod commitment;
pub mod utils;
pub mod poseidon_params;
