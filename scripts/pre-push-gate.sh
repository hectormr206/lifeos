#!/bin/bash
# Pre-push gate: fmt + clippy with the exact CI feature set.
# Replicates what CI's "Build Daemon" / "Build CLI" jobs enforce so
# cosmetic failures are caught locally instead of burning 20+ min of CI.
#
# Usage: bash scripts/pre-push-gate.sh
# Exit 0 = safe to push. Exit !=0 = fix before pushing.

set -euo pipefail

CI_FEATURES="dbus,http-api,ui-overlay,wake-word,messaging"

echo "[gate] cargo fmt --check (cli)"
cargo fmt --manifest-path cli/Cargo.toml -- --check

echo "[gate] cargo fmt --check (daemon)"
cargo fmt --manifest-path daemon/Cargo.toml -- --check

echo "[gate] cargo clippy --all-features -- -D warnings (cli)"
cargo clippy -p life --all-features -- -D warnings

echo "[gate] cargo clippy --features \"$CI_FEATURES\" -- -D warnings (daemon)"
cargo clippy -p lifeosd --features "$CI_FEATURES" -- -D warnings

echo "[gate] OK — safe to push."
