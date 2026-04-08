#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

errors=0

PUBLIC_CLAIM_PATHS=(
  "README.md"
  "docs/public"
)

LIVE_DOC_PATHS=(
  "README.md"
  "CONTRIBUTING.md"
  "docs/operations"
  "docs/public"
  "docs/user"
)

check_file() {
  local file="$1"
  if [ -f "$file" ]; then
    printf "${GREEN}[OK]${NC} %s\n" "$file"
  else
    printf "${RED}[FAIL]${NC} missing %s\n" "$file"
    errors=$((errors + 1))
  fi
}

check_pattern() {
  local pattern="$1"
  local file="$2"
  if rg -Fq -- "$pattern" "$file"; then
    printf "${GREEN}[OK]${NC} %s :: %s\n" "$file" "$pattern"
  else
    printf "${RED}[FAIL]${NC} %s :: missing %s\n" "$file" "$pattern"
    errors=$((errors + 1))
  fi
}

check_absent_in_paths() {
  local pattern="$1"
  local label="$2"
  shift 2
  if rg -n -F -- "$pattern" "$@" >/tmp/lifeos-truth-alignment-hit.txt 2>/dev/null; then
    printf "${RED}[FAIL]${NC} %s :: forbidden pattern found\n" "$label"
    sed 's/^/    /' /tmp/lifeos-truth-alignment-hit.txt
    errors=$((errors + 1))
  else
    printf "${GREEN}[OK]${NC} %s\n" "$label"
  fi
}

check_cli_help_if_available() {
  if [ ! -x "./target/release/life" ]; then
    printf "${YELLOW}[SKIP]${NC} CLI help smoke test skipped (target/release/life not present)\n"
    return
  fi

  local update_help
  local root_help
  update_help="$(./target/release/life update --help 2>/dev/null || true)"
  root_help="$(./target/release/life --help 2>/dev/null || true)"

  if [[ "$update_help" == *"status"* ]] && [[ "$update_help" == *"--channel <CHANNEL>"* ]]; then
    printf "${GREEN}[OK]${NC} CLI help exposes current documented update surface\n"
  else
    printf "${RED}[FAIL]${NC} CLI help no longer matches documented update surface\n"
    errors=$((errors + 1))
  fi

  if [[ "$root_help" == *$'\n  channel '* ]]; then
    printf "${RED}[FAIL]${NC} CLI unexpectedly exposes a top-level channel command\n"
    errors=$((errors + 1))
  else
    printf "${GREEN}[OK]${NC} CLI help does not expose a top-level channel command\n"
  fi
}

echo "Truth Alignment guardrails"
echo "=========================="

echo
echo "Canonical source files"
check_file "docs/architecture/update-channels.md"
check_file "docs/architecture/service-runtime.md"
check_file "docs/public/README.md"
check_file "docs/contributor/claim-vs-runtime-checklist.md"

echo
echo "Canonical update model"
check_pattern '1. `bootc` is the runtime authority on the host.' "docs/architecture/update-channels.md"
check_pattern '2. The signed GHCR image digest is the release artifact that `bootc` stages/boots.' "docs/architecture/update-channels.md"
check_pattern '3. `channels/*.json` is CI publication metadata that points at the latest digest per channel.' "docs/architecture/update-channels.md"
check_pattern '4. `/etc/lifeos/channels.toml` and `[updates]` in `lifeos.toml` only express local preference/policy.' "docs/architecture/update-channels.md"
check_pattern '# There is no shipped `life channel set` command yet.' "docs/architecture/update-channels.md"
check_pattern "sudo bootc switch ghcr.io/hectormr206/lifeos:stable" "docs/architecture/update-channels.md"

echo
echo "Canonical service runtime"
check_pattern '| `lifeosd` | `systemd --user` |' "docs/architecture/service-runtime.md"
check_pattern '| `llama-server` | `systemd` de sistema |' "docs/architecture/service-runtime.md"
check_pattern "systemctl --user status lifeosd" "docs/architecture/service-runtime.md"
check_pattern "sudo systemctl status llama-server" "docs/architecture/service-runtime.md"
check_pattern "systemctl --user status lifeosd --no-pager" "docs/operations/bootc-playbook.md"
check_pattern "sudo systemctl status llama-server --no-pager" "docs/operations/bootc-playbook.md"
check_pattern "systemctl --user status lifeosd" "docs/operations/system-admin.md"
check_pattern "sudo systemctl status llama-server" "docs/operations/system-admin.md"

echo
echo "Public claim taxonomy"
check_pattern "- **validated on host**" "docs/public/README.md"
check_pattern "- **integrated in repo**" "docs/public/README.md"
check_pattern "- **experimental**" "docs/public/README.md"
check_pattern "- **shipped disabled / feature-gated**" "docs/public/README.md"
check_absent_in_paths '(`shipped by default`)' "Public docs do not invent extra maturity labels" "${PUBLIC_CLAIM_PATHS[@]}"
check_absent_in_paths '(`validated on host, under watch`)' "Public docs do not invent composite maturity labels" "${PUBLIC_CLAIM_PATHS[@]}"

echo
echo "Forbidden drift patterns in live docs"
check_absent_in_paths '`life channel set`' "No phantom life channel set command" "${LIVE_DOC_PATHS[@]}"
check_absent_in_paths '`life channel switch`' "No phantom life channel switch command" "${LIVE_DOC_PATHS[@]}"
check_absent_in_paths '`life update channel`' "No phantom life update channel command" "${LIVE_DOC_PATHS[@]}"
check_absent_in_paths 'sudo systemctl restart lifeosd' "lifeosd is not documented as restartable via system scope" "${LIVE_DOC_PATHS[@]}"
check_absent_in_paths 'sudo systemctl start lifeosd' "lifeosd is not documented as startable via system scope" "${LIVE_DOC_PATHS[@]}"
check_absent_in_paths 'sudo systemctl stop lifeosd' "lifeosd is not documented as stoppable via system scope" "${LIVE_DOC_PATHS[@]}"
check_absent_in_paths 'sudo systemctl enable lifeosd' "lifeosd is not documented as enableable via system scope" "${LIVE_DOC_PATHS[@]}"
check_absent_in_paths 'journalctl -u lifeosd -f' "lifeosd logs are documented via user scope" "${LIVE_DOC_PATHS[@]}"

echo
echo "Optional CLI smoke test"
check_cli_help_if_available

rm -f /tmp/lifeos-truth-alignment-hit.txt

echo
if [ "$errors" -eq 0 ]; then
  printf "${GREEN}All truth alignment guardrails passed.${NC}\n"
else
  printf "${RED}%s truth alignment issue(s) found.${NC}\n" "$errors"
  exit 1
fi
