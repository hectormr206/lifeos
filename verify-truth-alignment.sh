#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================================"
echo "      LifeOS Truth Alignment Sprint - Guardrails"
echo "======================================================"
echo

bash "$ROOT_DIR/scripts/check-truth-alignment.sh"

echo
echo "Recommended runtime spot-checks on a target host:"
echo "  ./target/release/life update --help"
echo "  systemctl --user status lifeosd --no-pager"
echo "  sudo systemctl status llama-server --no-pager"
echo "  sudo bootc status"
