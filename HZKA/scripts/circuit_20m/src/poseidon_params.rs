//! Standard Poseidon hash parameters for the BN254 scalar field.
//!
//! Configuration:
//!   - Rate:           2 (absorb 2 field elements per permutation)
//!   - Capacity:       1 (width = rate + capacity = 3)
//!   - Full rounds:    8  (4 at start, 4 at end)
//!   - Partial rounds: 57 (provides ≥128-bit security on ~254-bit field)
//!   - S-box (α):      x^5  (gcd(5, p-1) = 1 for BN254 scalar field)
//!
//! Round constants and MDS matrix are derived from the Grain LFSR, matching
//! the reference Poseidon specification (Grassi et al., USENIX Security 2021).

use ark_bn254::Fr;
use ark_crypto_primitives::sponge::poseidon::PoseidonConfig;

/// Generate standard Poseidon parameters for BN254 Fr.
///
/// This function computes round constants (ARK) and the MDS matrix at runtime
/// using `find_poseidon_ark_and_mds`, which implements the Grain LFSR specified
/// in the Poseidon paper.  The result is deterministic and cached by callers.
pub fn bn254_poseidon_config() -> PoseidonConfig<Fr> {
    use ark_crypto_primitives::sponge::poseidon::find_poseidon_ark_and_mds;

    let full_rounds: usize = 8;
    let partial_rounds: usize = 57;
    let alpha: u64 = 5; // S-box exponent x^5
    let rate: usize = 2;
    let capacity: usize = 1;

    let (ark, mds) = find_poseidon_ark_and_mds::<Fr>(
        254,                  // BN254 scalar field bit size
        rate as u64,          // rate
        full_rounds as u64,   // full rounds
        partial_rounds as u64, // partial rounds
        0,                    // skip_matrices
    );

    PoseidonConfig::new(full_rounds, partial_rounds, alpha, mds, ark, rate, capacity)
}
