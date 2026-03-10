#!/usr/bin/env bash
# Deterministic local verification flow for Phase 3 hardening.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Try to load Rust toolchain from rustup if PATH is incomplete.
for env_file in "$HOME/.cargo/env" "/var/home/${USER:-lifeos}/.cargo/env"; do
    if [ -f "$env_file" ]; then
        # shellcheck disable=SC1090
        . "$env_file"
        break
    fi
done
export PATH="$HOME/.cargo/bin:/var/home/${USER:-lifeos}/.cargo/bin:$PATH"

cd "${PROJECT_ROOT}"

echo "[1/5] Validating daemon prerequisites..."
bash scripts/check-daemon-prereqs.sh

echo "[2/5] Checking formatting..."
cargo fmt --all -- --check

echo "[3/5] Running clippy..."
cargo clippy --workspace --all-targets --all-features -- -D warnings

echo "[4/5] Running workspace tests..."
cargo test --workspace --all-features --no-fail-fast

echo "[5/5] Running integration tests..."
cargo test --package lifeos-integration-tests --no-fail-fast -- --test-threads=1

echo "Phase 3 hardening checks passed."
