// Utility functions for the prover harness.

use std::path::Path;
use std::time::Instant;

/// Time a closure and return (result, elapsed_seconds).
pub fn timed<F, T>(label: &str, f: F) -> (T, f64)
where
    F: FnOnce() -> T,
{
    let start = Instant::now();
    let result = f();
    let elapsed = start.elapsed().as_secs_f64();
    eprintln!("[{label}] completed in {elapsed:.2}s");
    (result, elapsed)
}

/// Ensure a directory exists.
pub fn ensure_dir(path: &Path) {
    if !path.exists() {
        std::fs::create_dir_all(path).expect("Failed to create output directory");
    }
}
