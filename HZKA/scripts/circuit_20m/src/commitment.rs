// Poseidon commitment utility for binding member roots.
//
// In the full implementation, this would use ark-crypto-primitives'
// PoseidonSponge with BN254-optimised parameters.  For the scaffold,
// we provide a simple hash placeholder.

use ark_bn254::Fr;
use ark_ff::Field;

/// Compute a simple commitment over a set of field elements.
///
/// In production, replace with Poseidon hash:
/// ```ignore
/// use ark_crypto_primitives::sponge::poseidon::PoseidonSponge;
/// use ark_crypto_primitives::sponge::CryptographicSponge;
/// ```
pub fn compute_commitment(roots: &[Fr]) -> Fr {
    if roots.is_empty() {
        return Fr::from(0u64);
    }
    let mut acc = roots[0];
    for r in &roots[1..] {
        acc += r;
    }
    acc
}
