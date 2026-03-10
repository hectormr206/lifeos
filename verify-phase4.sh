#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      LifeOS Phase 4 - Sensory Repository Verification      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

bash "$ROOT_DIR/scripts/phase4-sensory-checks.sh"

echo
echo "Recommended runtime checks on a machine with Rust toolchain and local models:"
echo "  cd daemon && cargo run --all-features"
echo "  cd cli && cargo run -- voice pipeline-status"
echo "  cd cli && cargo run -- voice session --prompt \"Hey Axi, dame estado\""
echo "  cd cli && cargo run -- voice describe-screen --question \"Que ves en mi pantalla?\""
echo "  cd cli && cargo run -- ai bench-sensory --prompt \"Hey Axi, resume el sistema\" --repeats 2"
