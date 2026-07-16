#!/usr/bin/env bash
# Overnight ADDENDUM 2 — complete the 16x2 speed matrix.
# Adds the missing crossed cells: GPU (vram12) speed for the small models
# and CPU speed for the heavy models. Speed-only runs (cheap). Assumes it
# fires while the machine is quiet; uses the same offline discipline.
set -u
REPO=/home/hectormr/LifeOS/lifeos
PY=$REPO/lifeos/.venv/bin/python
AUDIT="$REPO/axi/scripts/bench/model_audit.py"
M=/home/hectormr/LifeOS/models
FORK=/home/hectormr/LifeOS/PrismML-llama.cpp/build/bin/llama-server
LOGDIR=$REPO/axi/scripts/bench/results/overnight-$(date +%Y%m%d)-speed
mkdir -p "$LOGDIR"
cd "$REPO/axi"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOGDIR/driver.log"; }

log "=== ADDENDUM2 quiet+offline ==="
systemctl --user stop axi-heartbeat.service axi-voice.service \
  axi-whisper.service axi-tray.service axi-dashboard.service \
  >> "$LOGDIR/driver.log" 2>&1
bash "$REPO/axi/scripts/axi-game-on" --offline >> "$LOGDIR/driver.log" 2>&1
sleep 5

speed() { # label tier gguf extra-args...
  local lbl=$1 tier=$2 gguf=$3; shift 3
  # vram tiers also run the ctx_max probe (two extra spawns); cpu has no
  # VRAM ceiling so the probe is meaningless there.
  local roles=speed
  [ "$tier" != cpu ] && roles=speed,ctxprobe
  log "SPEED $lbl $tier (roles=$roles)"
  "$PY" "$AUDIT" --label "$lbl" --gguf "$gguf" --tiers "$tier" \
    --roles "$roles" --thinking-modes none "$@" \
    > "$LOGDIR/speed_${lbl}_${tier}.log" 2>&1
  log "SPEED $lbl $tier exit=$?"
}

# GPU speed for the small models (cpu-tier quality already recorded).
speed qwen35-0_8b   vram12 "$M/qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf"
speed qwen35-2b     vram12 "$M/qwen35-2b/Qwen3.5-2B-Q4_K_M.gguf"
speed qwen35-4b     vram12 "$M/qwen35-4b/Qwen3.5-4B-Q4_K_M.gguf"
speed gemma4-e2b    vram12 "$M/gemma4-e2b-it/gemma-4-E2B-it-Q4_K_M.gguf" --extra-flags --reasoning off
speed gemma4-e4b    vram12 "$M/gemma4-e4b-it/gemma-4-E4B-it-Q4_K_M.gguf" --extra-flags --reasoning off
speed vibethinker-3b vram12 "$M/vibethinker-3b/VibeThinker-3B-Q4_K_M.gguf"

# CPU speed for the heavy models (vram12 quality recorded by the marathon).
speed bonsai-1bit   cpu "$M/bonsai-27b/Bonsai-27B-Q1_0.gguf" --server-bin "$FORK"
speed bonsai-ternary cpu "$M/bonsai-27b/Ternary-Bonsai-27B-Q2_0.gguf" --server-bin "$FORK"
speed gemma4-26b    cpu "$M/gemma4-26b-a4b/gemma-4-26B-A4B-it-Q4_K_M.gguf" --moe on --extra-flags --reasoning off
speed nemotron-cascade2-30b cpu "$M/nemotron-cascade2-30b/Nemotron-Cascade-2-30B-A3B-Q4_K_M.gguf" --moe on
speed diffusiongemma-26b cpu "$M/diffusiongemma-26b/diffusiongemma-26B-A4B-it-Q4_K_M.gguf" --moe on --extra-flags --reasoning off
speed qwen3-omni-30b cpu "$M/qwen3-omni-30b/Qwen3-Omni-30B-A3B-Instruct-Q4_K_M.gguf" --moe on
speed laguna-xs-2.1 cpu "$M/laguna-xs-2.1/Laguna-XS-2.1-Q4_K_M.gguf" --moe on
speed qwen36-27b    cpu "$M/qwen36-27b/Qwen3.6-27B-Q4_K_M.gguf" --moe off
speed qwen36-35b    cpu "$M/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf" --moe on

log "=== ADDENDUM2 restore ==="
bash "$REPO/axi/scripts/axi-game-off" >> "$LOGDIR/driver.log" 2>&1
systemctl --user start axi-dashboard.service
sleep 5
systemctl --user start axi-whisper.service axi-tray.service axi-voice.service
sleep 3
systemctl --user start axi-heartbeat.service
log "=== ADDENDUM2 FINAL MATRIX ==="
"$PY" "$AUDIT" --compare | tee -a "$LOGDIR/driver.log"
log "ADDENDUM2 COMPLETE"
