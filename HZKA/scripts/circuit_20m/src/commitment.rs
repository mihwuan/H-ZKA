//! Poseidon commitment and state transition utilities (native / non-circuit).
//!
//! This module provides the NATIVE (outside-the-circuit) counterparts of the
//! Poseidon operations used inside the aggregation circuit.  They are called
//! during witness generation to produce values that the in-circuit
//! `PoseidonSpongeVar` will verify.
//!
//! - [`compute_commitment`]: B_max-1 sequential Poseidon compressions binding
//!   all member roots into a single cluster commitment.
//! - [`compute_state_transition`]: Poseidon(old_root, tx_data) → new_root.

use ark_bn254::Fr;
use ark_crypto_primitives::sponge::{
    poseidon::{PoseidonConfig, PoseidonSponge},
    CryptographicSponge,
};

/// Compute the cluster commitment as B_max-1 sequential Poseidon compressions.
///
/// ```text
/// acc = root[0]
/// for i in 1..B_max:
///     acc = Poseidon(acc, root[i])
/// commitment = acc
/// ```
///
/// This matches Algorithm 1 in the manuscript: "the commitment binding all
/// member roots using B_max-1 Poseidon compressions inside the circuit."
pub fn compute_commitment(poseidon_config: &PoseidonConfig<Fr>, roots: &[Fr]) -> Fr {
    assert!(!roots.is_empty(), "At least one root required for commitment");

    let mut acc = roots[0];
    for root in &roots[1..] {
        let mut sponge = PoseidonSponge::new(poseidon_config);
        sponge.absorb(&acc);
        sponge.absorb(root);
        acc = sponge.squeeze_field_elements(1)[0];
    }
    acc
}

/// Compute a state transition: new_root = Poseidon(old_root, tx_data).
///
/// Verifies the relation from TODO.tex §1:
///   StateTransition(rt^old_j, tx_j) = rt^new_j
pub fn compute_state_transition(
    poseidon_config: &PoseidonConfig<Fr>,
    old_root: &Fr,
    tx_data: &Fr,
) -> Fr {
    let mut sponge = PoseidonSponge::new(poseidon_config);
    sponge.absorb(old_root);
    sponge.absorb(tx_data);
    sponge.squeeze_field_elements(1)[0]
}
