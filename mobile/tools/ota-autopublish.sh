#!/usr/bin/env bash
# ota-autopublish.sh — publish an OTA update once CI goes green on main.
#
# Runs on the HOST as the owning user, driven by the lifeos-ota-autopublish
# systemd timer. CI deliberately does not publish: its jobs run in a container
# with no access to the Flutter/Android SDKs, the release keystore or
# ~/lifeos-updates, and this repository is public — putting the signing key
# within reach of its CI would expose the key the installed app trusts. So CI
# verifies, and this script signs and ships.
#
# Idempotent and safe to run on a short timer: it exits without doing anything
# unless origin/main has a commit that is both newer than the last published
# one and green in CI.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lifeos-ota"
STATE_FILE="$STATE_DIR/last-published-sha"
LOCK_FILE="$STATE_DIR/autopublish.lock"
BRANCH="main"
WORKFLOW="CI"

mkdir -p "$STATE_DIR"

# Serialize: a build takes minutes, the timer fires more often than that.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "→ Ya hay una publicación en curso; salgo."
  exit 0
fi

log() { echo "[$(date -Is)] $*"; }

cd "$REPO_ROOT"

# ── Preconditions ───────────────────────────────────────────────────────────
# Never publish from a branch the user is actively working on, and never build
# a tree that does not match the reviewed commit. Untracked files are fine
# (bench results live in the tree); modified tracked files are not.
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
  log "→ En '$CURRENT_BRANCH', no en '$BRANCH'. Nada que hacer."
  exit 0
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  log "→ Hay cambios sin commitear en archivos versionados. No publico."
  exit 0
fi

git fetch --quiet origin "$BRANCH"
REMOTE_SHA="$(git rev-parse "origin/$BRANCH")"
LAST_SHA="$(cat "$STATE_FILE" 2>/dev/null || echo '')"

if [[ "$REMOTE_SHA" == "$LAST_SHA" ]]; then
  log "→ ${REMOTE_SHA:0:8} ya fue publicado. Nada que hacer."
  exit 0
fi

# ── Gate: only ship what CI proved green ────────────────────────────────────
CONCLUSION="$(gh run list --commit "$REMOTE_SHA" --workflow "$WORKFLOW" \
  --limit 1 --json conclusion --jq '.[0].conclusion // "none"' 2>/dev/null || echo 'none')"

case "$CONCLUSION" in
  success) log "→ CI en verde para ${REMOTE_SHA:0:8}. Publicando…" ;;
  none|null|"")
    log "→ CI todavía no reportó para ${REMOTE_SHA:0:8}. Espero al próximo ciclo."
    exit 0 ;;
  *)
    log "→ CI terminó en '$CONCLUSION' para ${REMOTE_SHA:0:8}. NO publico."
    exit 0 ;;
esac

# ── Fast-forward to the reviewed commit and ship it ─────────────────────────
git merge --ff-only "origin/$BRANCH"

cd "$REPO_ROOT/mobile"
flutter pub get
NOTES="$(git -C "$REPO_ROOT" log -1 --format='%h %s')"
./tools/publish-to-vps.sh "$NOTES"

# Record only after a successful publish, so a failure retries next cycle.
echo "$REMOTE_SHA" > "$STATE_FILE"
log "✓ Publicado ${REMOTE_SHA:0:8} — $NOTES"
