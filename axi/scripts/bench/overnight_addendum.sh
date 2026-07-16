#!/usr/bin/env bash
# Overnight ADDENDUM — runs AFTER overnight_roster.sh completes.
# Re-scores the remaining pre-seed-era roles for the four models audited
# before the 2026-07-16 pinned-seed era, so EVERY card in the registry is
# one consistent, comparable era by morning. Uses saved recipes (no
# re-tuning). Assumes Axi is already restored (runs post-driver): it uses
# quiet-mode + stand-in judge again, then restores again.
set -u
REPO=/home/hectormr/LifeOS/lifeos
PY=$REPO/lifeos/.venv/bin/python
AUDIT="$REPO/axi/scripts/bench/model_audit.py"
M=/home/hectormr/LifeOS/models
LOGDIR=$REPO/axi/scripts/bench/results/overnight-$(date +%Y%m%d)-addendum
mkdir -p "$LOGDIR"
cd "$REPO/axi"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOGDIR/driver.log"; }

ROLES="toolcall,codereview,vision,codegen,recordsqa,longsum,parsejson,visionclass,devplan"

log "=== ADDENDUM quiet mode ==="
systemctl --user stop axi-heartbeat.service axi-voice.service \
  axi-whisper.service axi-tray.service axi-dashboard.service \
  >> "$LOGDIR/driver.log" 2>&1
bash "$REPO/axi/scripts/axi-game-on" --offline >> "$LOGDIR/driver.log" 2>&1
sleep 5
CUDA_VISIBLE_DEVICES="" nohup /usr/bin/llama-server \
  -m "$M/qwen35-4b/Qwen3.5-4B-Q4_K_M.gguf" \
  -ngl 0 --jinja -c 16384 --host 127.0.0.1 --port 8080 -t 6 --no-mmap -np 1 \
  > "$LOGDIR/judge_standin.log" 2>&1 &
JUDGE_PID=$!
for i in $(seq 1 60); do
  sleep 2
  curl -s http://127.0.0.1:8080/health 2>/dev/null | grep -q ok && break
done
log "stand-in judge pid=$JUDGE_PID"

for spec in \
  "qwen35-4b|$M/qwen35-4b/Qwen3.5-4B-Q4_K_M.gguf|$M/qwen35-4b/mmproj-F16.gguf" \
  "qwen35-0_8b|$M/qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf|$M/qwen35-0_8b/mmproj-F16.gguf" \
  "qwen35-2b|$M/qwen35-2b/Qwen3.5-2B-Q4_K_M.gguf|$M/qwen35-2b/mmproj-F16.gguf" \
  "gemma4-e2b|$M/gemma4-e2b-it/gemma-4-E2B-it-Q4_K_M.gguf|$M/gemma4-e2b-it/mmproj-BF16.gguf" ; do
  IFS='|' read -r lbl gguf mmproj <<<"$spec"
  extra=()
  [[ $lbl == gemma* ]] && extra=(--extra-flags --reasoning off)
  log "ERA-BACKFILL $lbl ($ROLES)"
  "$PY" "$AUDIT" --label "$lbl" --gguf "$gguf" --mmproj "$mmproj" \
    --tiers cpu --use-recipe --roles "$ROLES" "${extra[@]}" \
    > "$LOGDIR/backfill_$lbl.log" 2>&1
  log "ERA-BACKFILL $lbl exit=$?"
done

log "=== ADDENDUM restore ==="
kill "$JUDGE_PID" 2>/dev/null
sleep 3
bash "$REPO/axi/scripts/axi-game-off" >> "$LOGDIR/driver.log" 2>&1
systemctl --user start axi-dashboard.service
sleep 5
systemctl --user start axi-whisper.service axi-tray.service axi-voice.service
sleep 3
systemctl --user start axi-heartbeat.service
log "=== ADDENDUM FINAL MATRIX ==="
"$PY" "$AUDIT" --compare | tee -a "$LOGDIR/driver.log"
log "ADDENDUM COMPLETE"
