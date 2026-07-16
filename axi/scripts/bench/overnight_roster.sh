#!/usr/bin/env bash
# Overnight roster audit driver (2026-07-15 marathon).
#
# Block A (prod judge up, CPU): remaining small models + corrected
#   agentic/proactive backfills for the already-audited four.
# Block B (axi offline, GPU): heavy models get FULL quality on GPU (fast)
#   with a stand-in CPU judge on :8080, then vram12/vram8 speed sweeps.
# End: restore Axi, re-enable nightly self-improve, print the matrix.
#
# Deliberately NOT `set -e`: one model failing must never kill the night.
set -u
REPO=/home/hectormr/LifeOS/lifeos
PY=$REPO/lifeos/.venv/bin/python
AUDIT="$REPO/axi/scripts/bench/model_audit.py"
M=/home/hectormr/LifeOS/models
FORK=/home/hectormr/LifeOS/PrismML-llama.cpp/build/bin/llama-server
LOGDIR=$REPO/axi/scripts/bench/results/overnight-$(date +%Y%m%d)
mkdir -p "$LOGDIR"
cd "$REPO/axi"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOGDIR/driver.log"; }

run_audit() { # label log-name args...
  local label=$1 lname=$2; shift 2
  log "AUDIT $label start"
  "$PY" "$AUDIT" --label "$label" "$@" > "$LOGDIR/$lname.log" 2>&1
  log "AUDIT $label exit=$?"
}

# ─── Quiet mode: silence every scheduled CPU consumer for the night ─────
# Order matters: heartbeat first (it resurrects axi-voice), then the rest.
# axi-dashboard hosts ALL crons (morning news briefing, adaptive digest,
# autonomous agent, posture) — stopping it silences them in one blow.
# llama-server stays up: it IS the Block-A judge.
log "=== QUIET MODE: stopping heartbeat/voice/whisper/tray/dashboard ==="
systemctl --user stop axi-heartbeat.service axi-voice.service \
  axi-whisper.service axi-tray.service axi-dashboard.service \
  >> "$LOGDIR/driver.log" 2>&1
sleep 3

# ─── Block A: prod judge alive — CPU quality ────────────────────────────
log "=== BLOCK A: CPU quality (prod judge on 8080) ==="

run_audit gemma4-e4b a_e4b \
  --gguf "$M/gemma4-e4b-it/gemma-4-E4B-it-Q4_K_M.gguf" \
  --tiers cpu --thinking-modes off --extra-flags --reasoning off

run_audit vibethinker-3b a_vt3b \
  --gguf "$M/vibethinker-3b/VibeThinker-3B-Q4_K_M.gguf" \
  --tiers cpu --thinking-modes on,off

# Pinned-seed era backfills (2026-07-16): the sampling-sensitive roles are
# re-scored at deterministic per-case seeds so the already-audited four are
# comparable with every model audited from tonight on.
for spec in \
  "qwen35-4b|$M/qwen35-4b/Qwen3.5-4B-Q4_K_M.gguf|$M/qwen35-4b/mmproj-F16.gguf" \
  "qwen35-0_8b|$M/qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf|$M/qwen35-0_8b/mmproj-F16.gguf" \
  "qwen35-2b|$M/qwen35-2b/Qwen3.5-2B-Q4_K_M.gguf|$M/qwen35-2b/mmproj-F16.gguf" \
  "gemma4-e2b|$M/gemma4-e2b-it/gemma-4-E2B-it-Q4_K_M.gguf|$M/gemma4-e2b-it/mmproj-BF16.gguf" ; do
  IFS='|' read -r lbl gguf mmproj <<<"$spec"
  extra=()
  [[ $lbl == gemma* ]] && extra=(--extra-flags --reasoning off)
  log "BACKFILL $lbl brain+conversation+narration+agentic+proactive+toolstress (pinned-seed era)"
  "$PY" "$AUDIT" --label "$lbl" --gguf "$gguf" --mmproj "$mmproj" \
    --tiers cpu --use-recipe \
    --roles brain,conversation,narration,agentic,proactive,toolstress "${extra[@]}" \
    > "$LOGDIR/a_backfill_$lbl.log" 2>&1
  log "BACKFILL $lbl exit=$?"
done

# ─── Block B: free VRAM, stand-in CPU judge, GPU quality for heavies ────
log "=== BLOCK B: GPU quality (axi offline, stand-in CPU judge) ==="
bash "$REPO/axi/scripts/axi-game-on" --offline >> "$LOGDIR/driver.log" 2>&1
sleep 5

# Stand-in judge: qwen35-4b CPU-only on 8080 (same model class as the day
# judge). Short judge calls only — CPU speed is fine.
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

# Heavy models — full quality on GPU (vram12 tier). MoE models marked.
run_audit bonsai-1bit b_bonsai1 \
  --gguf "$M/bonsai-27b/Bonsai-27B-Q1_0.gguf" \
  --mmproj "$M/bonsai-27b/Bonsai-27B-mmproj-Q8_0.gguf" \
  --server-bin "$FORK" --tiers vram12 --thinking-modes off,on

run_audit bonsai-ternary b_bonsait \
  --gguf "$M/bonsai-27b/Ternary-Bonsai-27B-Q2_0.gguf" \
  --mmproj "$M/bonsai-27b/Ternary-Bonsai-27B-mmproj-Q8_0.gguf" \
  --server-bin "$FORK" --tiers vram12 --thinking-modes off,on

run_audit gemma4-26b b_26b \
  --gguf "$M/gemma4-26b-a4b/gemma-4-26B-A4B-it-Q4_K_M.gguf" \
  --mmproj "$M/gemma4-26b-a4b/mmproj-F16.gguf" \
  --tiers vram12 --thinking-modes off --moe on --extra-flags --reasoning off

run_audit nemotron-cascade2-30b b_cascade \
  --gguf "$M/nemotron-cascade2-30b/Nemotron-Cascade-2-30B-A3B-Q4_K_M.gguf" \
  --tiers vram12 --thinking-modes off,on --moe on

run_audit diffusiongemma-26b b_diffusion \
  --gguf "$M/diffusiongemma-26b/diffusiongemma-26B-A4B-it-Q4_K_M.gguf" \
  --tiers vram12 --thinking-modes off --moe on --extra-flags --reasoning off

run_audit qwen3-omni-30b b_omni \
  --gguf "$M/qwen3-omni-30b/Qwen3-Omni-30B-A3B-Instruct-Q4_K_M.gguf" \
  --tiers vram12 --thinking-modes off,on --moe on

run_audit laguna-xs-2.1 b_laguna \
  --gguf "$M/laguna-xs-2.1/Laguna-XS-2.1-Q4_K_M.gguf" \
  --tiers vram12 --thinking-modes off,on --moe on

run_audit qwen36-27b b_27b \
  --gguf "$M/qwen36-27b/Qwen3.6-27B-Q4_K_M.gguf" \
  --mmproj "$M/qwen36-27b/mmproj-F16.gguf" \
  --tiers vram12 --thinking-modes off,on --moe off

run_audit qwen36-35b b_35b \
  --gguf "$M/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf" \
  --tiers vram12 --thinking-modes off,on --moe on

# vram8 speed sweeps (config tuning per tier; quality already recorded).
log "=== BLOCK B2: vram8 speed sweeps ==="
for spec in \
  "qwen35-4b|$M/qwen35-4b/Qwen3.5-4B-Q4_K_M.gguf" \
  "gemma4-e2b|$M/gemma4-e2b-it/gemma-4-E2B-it-Q4_K_M.gguf" \
  "bonsai-1bit|$M/bonsai-27b/Bonsai-27B-Q1_0.gguf" \
  "qwen36-35b|$M/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf" ; do
  IFS='|' read -r lbl gguf <<<"$spec"
  args=(--label "$lbl" --gguf "$gguf" --tiers vram8 --roles speed --thinking-modes none)
  [[ $lbl == bonsai* ]] && args+=(--server-bin "$FORK")
  [[ $lbl == qwen36-35b ]] && args+=(--moe on)
  [[ $lbl == gemma* ]] && args+=(--extra-flags --reasoning off)
  log "SPEED8 $lbl"
  "$PY" "$AUDIT" "${args[@]}" > "$LOGDIR/b2_speed8_$lbl.log" 2>&1
  log "SPEED8 $lbl exit=$?"
done

# ─── Restore everything ─────────────────────────────────────────────────
log "=== RESTORE ==="
kill "$JUDGE_PID" 2>/dev/null
sleep 3
bash "$REPO/axi/scripts/axi-game-off" >> "$LOGDIR/driver.log" 2>&1

# Re-enable the nightly self-improve DIRECTLY in config.json (the dashboard
# is still stopped at this point, so its API is unavailable). config.save()
# validates; axi-voice reads the flag fresh on start.
"$REPO/axi/.venv/bin/python" - <<'PYEOF' >> "$LOGDIR/driver.log" 2>&1
from axi import config
cfg = dict(config._load())
cfg["dev_self_improve_enabled"] = True
config.save(cfg)
print("dev_self_improve_enabled restored to True")
PYEOF

# Leave quiet mode: dashboard first (crons + audit page back), then voice
# stack, then heartbeat LAST (so it never sees a half-restored stack).
systemctl --user start axi-dashboard.service
sleep 5
systemctl --user start axi-whisper.service axi-tray.service axi-voice.service
sleep 3
systemctl --user start axi-heartbeat.service

log "=== FINAL MATRIX ==="
"$PY" "$AUDIT" --compare | tee -a "$LOGDIR/driver.log"
log "OVERNIGHT COMPLETE"
