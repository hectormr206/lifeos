#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

errors=0

check_file() {
    if [ -f "$1" ]; then
        printf "${GREEN}[OK]${NC} %s\n" "$1"
    else
        printf "${RED}[FAIL]${NC} %s\n" "$1"
        errors=$((errors + 1))
    fi
}

check_pattern() {
    local pattern="$1"
    local file="$2"
    if rg -Fq "$pattern" "$file"; then
        printf "${GREEN}[OK]${NC} %s :: %s\n" "$file" "$pattern"
    else
        printf "${RED}[FAIL]${NC} %s :: %s\n" "$file" "$pattern"
        errors=$((errors + 1))
    fi
}

echo "Phase 4.5 repo verification"
echo "==========================="

echo
echo "Core files"
check_file "daemon/src/api/mod.rs"
check_file "cli/src/commands/overlay.rs"
check_file "cli/src/main_tests.rs"
check_file "image/files/usr/local/bin/lifeos-ai-setup.sh"
check_file "image/files/etc/lifeos/llama-server.env"
check_file "docs/lifeos-ai-distribution.md"
check_file "docs/PROJECT_STATE.md"
check_file "PHASE45_SUMMARY.md"
check_file "evidence/phase-4.5/phase-4.5-closeout.md"
check_file "verify-phase45.sh"

echo
echo "Selector API and lifecycle routes"
check_pattern "/overlay/models" "daemon/src/api/mod.rs"
check_pattern "/overlay/models/select" "daemon/src/api/mod.rs"
check_pattern "/overlay/models/pull" "daemon/src/api/mod.rs"
check_pattern "/overlay/models/remove" "daemon/src/api/mod.rs"
check_pattern "/overlay/models/pin" "daemon/src/api/mod.rs"
check_pattern "/overlay/models/unpin" "daemon/src/api/mod.rs"
check_pattern "/overlay/models/cleanup" "daemon/src/api/mod.rs"
check_pattern "/overlay/models/export" "daemon/src/api/mod.rs"
check_pattern "/overlay/models/import" "daemon/src/api/mod.rs"

echo
echo "Fit/cost/storage guardrails"
check_pattern "featured_roster" "daemon/src/api/mod.rs"
check_pattern "fit_tier" "daemon/src/api/mod.rs"
check_pattern "expected_gpu_layers" "daemon/src/api/mod.rs"
check_pattern "expected_ram_gb" "daemon/src/api/mod.rs"
check_pattern "expected_vram_gb" "daemon/src/api/mod.rs"
check_pattern "required_disk_bytes" "daemon/src/api/mod.rs"
check_pattern "reclaimable_model_bytes" "daemon/src/api/mod.rs"
check_pattern "recalculate_gpu_layers_for_model" "daemon/src/api/mod.rs"
check_pattern "ensure_model_storage_capacity" "daemon/src/api/mod.rs"
check_pattern "cleanup_model_lifecycle_state" "daemon/src/api/mod.rs"
check_pattern "MODEL_LIFECYCLE_STATE_FILE" "daemon/src/api/mod.rs"
check_pattern "removed_by_user" "daemon/src/api/mod.rs"

echo
echo "Runtime coherence and update-safe behavior"
check_pattern "set_selected_model_in_lifecycle" "daemon/src/api/mod.rs"
check_pattern "LIFEOS_AI_GPU_LAYERS" "daemon/src/api/mod.rs"
check_pattern "LIFEOS_AI_AUTO_MANAGE_MODELS=false" "image/files/etc/lifeos/llama-server.env"
check_pattern "AUTO_MANAGE_MODELS" "image/files/usr/local/bin/lifeos-ai-setup.sh"
check_pattern "Auto model management disabled" "image/files/usr/local/bin/lifeos-ai-setup.sh"
check_pattern "REMOVED_MODELS_FILE" "image/files/usr/local/bin/lifeos-ai-setup.sh"
check_pattern "No local fallback model available. Heavy-model runtime remains disabled." "image/files/usr/local/bin/lifeos-ai-setup.sh"

echo
echo "CLI surfaces and parser coverage"
check_pattern "ModelCleanup" "cli/src/commands/overlay.rs"
check_pattern "ModelsExport" "cli/src/commands/overlay.rs"
check_pattern "ModelsImport" "cli/src/commands/overlay.rs"
check_pattern "model-cleanup" "cli/src/main_tests.rs"
check_pattern "test_cli_parses_overlay_model_cleanup_command" "cli/src/main_tests.rs"

echo
echo "Docs and closeout artifacts"
check_pattern "Fase 4.5" "docs/lifeos-ai-distribution.md"
check_pattern "Estado:** **CUMPLIDA (2026-03-15)." "docs/lifeos-ai-distribution.md"
check_pattern "Current Phase: Phase 4 and 4.5 Closed (Field Validated) / Phase 5 Pending" "docs/PROJECT_STATE.md"
check_pattern "Phase 4.5: **CLOSED IN REPO + FIELD VALIDATED**" "docs/PROJECT_STATE.md"
check_pattern "Phase 4.5 is closed in-repo and field validated as of 2026-03-15." "PHASE45_SUMMARY.md"
check_pattern "Phase 4.5 scope is closed in-repo" "evidence/phase-4.5/phase-4.5-closeout.md"

echo
if [ "$errors" -eq 0 ]; then
    printf "${GREEN}All Phase 4.5 repository checks passed.${NC}\n"
else
    printf "${RED}%s verification issue(s) found.${NC}\n" "$errors"
    exit 1
fi
