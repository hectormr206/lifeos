#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=============================================================="
echo "      LifeOS Phase 4.5 - Model Lifecycle Verification"
echo "=============================================================="
echo

bash "$ROOT_DIR/scripts/phase45-model-lifecycle-checks.sh"

echo
echo "Recommended runtime checks on a target machine:"
echo "  life ai status -v"
echo "  life overlay models"
echo "  life overlay model-cleanup --dry-run"
echo "  life overlay chat \"Describe mi pantalla en una frase\""
echo "  life voice describe-screen --question \"Describe exactamente mi pantalla\""
echo "  life ai bench-sensory --prompt \"Resume la pantalla en una frase\" --include-screen --repeats 3"
