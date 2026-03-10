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
        printf "${GREEN}✓${NC} %s\n" "$1"
    else
        printf "${RED}✗${NC} %s\n" "$1"
        errors=$((errors + 1))
    fi
}

check_pattern() {
    local pattern="$1"
    local file="$2"
    if rg -q "$pattern" "$file"; then
        printf "${GREEN}✓${NC} %s :: %s\n" "$file" "$pattern"
    else
        printf "${RED}✗${NC} %s :: %s\n" "$file" "$pattern"
        errors=$((errors + 1))
    fi
}

echo "Phase 4 repo verification"
echo "========================="

echo
echo "Core files"
check_file "daemon/src/sensory_pipeline.rs"
check_file "daemon/src/api/mod.rs"
check_file "daemon/src/main.rs"
check_file "daemon/src/overlay.rs"
check_file "daemon/src/agent_runtime.rs"
check_file "cli/src/commands/voice.rs"
check_file "cli/src/commands/ai.rs"
check_file "cli/src/commands/intents.rs"
check_file "cli/src/main_tests.rs"
check_file "docs/lifeos-ai-distribution.md"
check_file "docs/PROJECT_STATE.md"
check_file "PHASE4_SUMMARY.md"
check_file "evidence/phase-4/phase-4-closeout.md"

echo
echo "Sensory runtime"
check_pattern "run_always_on_cycle" "daemon/src/sensory_pipeline.rs"
check_pattern "capture_audio_snippet" "daemon/src/sensory_pipeline.rs"
check_pattern "audio_has_voice_activity" "daemon/src/sensory_pipeline.rs"
check_pattern "describe_screen" "daemon/src/sensory_pipeline.rs"
check_pattern "update_presence" "daemon/src/sensory_pipeline.rs"
check_pattern "gpu_policy_for_vram" "daemon/src/sensory_pipeline.rs"
check_pattern "persist_gpu_layers" "daemon/src/sensory_pipeline.rs"

echo
echo "API routes"
check_pattern "/sensory/status" "daemon/src/api/mod.rs"
check_pattern "/sensory/voice/session" "daemon/src/api/mod.rs"
check_pattern "/sensory/vision/describe" "daemon/src/api/mod.rs"
check_pattern "/sensory/presence" "daemon/src/api/mod.rs"
check_pattern "/sensory/benchmark" "daemon/src/api/mod.rs"
check_pattern "/sensory/kill-switch" "daemon/src/api/mod.rs"

echo
echo "CLI surfaces"
check_pattern "PipelineStatus" "cli/src/commands/voice.rs"
check_pattern "DescribeScreen" "cli/src/commands/voice.rs"
check_pattern "Presence" "cli/src/commands/voice.rs"
check_pattern "BenchSensory" "cli/src/commands/ai.rs"
check_pattern "camera" "cli/src/commands/intents.rs"
check_pattern "interval" "cli/src/commands/intents.rs"

echo
echo "Overlay/Axi"
check_pattern "enum AxiState" "daemon/src/overlay.rs"
check_pattern "Night" "daemon/src/overlay.rs"
check_pattern "set_sensor_indicators" "daemon/src/overlay.rs"
check_pattern "push_proactive_notification" "daemon/src/overlay.rs"
check_pattern "mini_widget" "daemon/src/overlay.rs"

echo
echo "Docs and closeout"
check_pattern "CERRADA EN REPO" "docs/lifeos-ai-distribution.md"
check_pattern "Estado de salida" "docs/lifeos-ai-distribution.md"
check_pattern "Phase 4: \\*\\*CLOSED IN REPO\\*\\*" "docs/PROJECT_STATE.md"
check_pattern "Sensory Interaction Closeout" "PHASE4_SUMMARY.md"

echo
if [ "$errors" -eq 0 ]; then
    printf "${GREEN}All Phase 4 repository checks passed.${NC}\n"
else
    printf "${RED}%s verification issue(s) found.${NC}\n" "$errors"
    exit 1
fi
