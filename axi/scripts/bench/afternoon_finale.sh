#!/usr/bin/env bash
# Afternoon finale (2026-07-16) — everything still missing, in one chain.
# Per Héctor: run right after his meeting; GPU for everything that can;
# dashboard STAYS UP so he can watch /models/audit live.
#
# Chain: offline + stand-in judge → 35B (vram12, the title match) →
# e4b + VT-3B re-audits (vram12 — fresh cards, fast) → 4 small models'
# remaining 9 roles (cpu, era unification) → speed matrix + ctxprobe
# (vram12 crosses + cpu crosses) → full restore + re-enable self-improve.
set -u
REPO=/home/hectormr/LifeOS/lifeos
PY=$REPO/lifeos/.venv/bin/python
AUDIT="$REPO/axi/scripts/bench/model_audit.py"
M=/home/hectormr/LifeOS/models
FORK=/home/hectormr/LifeOS/PrismML-llama.cpp/build/bin/llama-server
LOGDIR=$REPO/axi/scripts/bench/results/finale-$(date +%Y%m%d-%H%M)
mkdir -p "$LOGDIR"
cd "$REPO/axi"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOGDIR/driver.log"; }

run_audit() { # label log-name args...
  local label=$1 lname=$2; shift 2
  log "AUDIT $label start"
  "$PY" "$AUDIT" --label "$label" "$@" > "$LOGDIR/$lname.log" 2>&1
  log "AUDIT $label exit=$?"
}

# ─── Quiet-ish mode: voice stack down, DASHBOARD STAYS UP ────────────────
log "=== quiet-ish mode (dashboard stays up for live viewing) ==="
systemctl --user stop axi-heartbeat.service axi-voice.service \
  axi-whisper.service axi-tray.service >> "$LOGDIR/driver.log" 2>&1
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

# ─── The title match: Qwen3.6-35B (nightly-dev incumbent) ────────────────
run_audit qwen36-35b f_35b \
  --gguf "$M/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf" \
  --tiers vram12 --thinking-modes off,on --moe on

# ─── Marathon casualties: fresh full audits on GPU (fast, single-tier) ───
run_audit gemma4-e4b f_e4b \
  --gguf "$M/gemma4-e4b-it/gemma-4-E4B-it-Q4_K_M.gguf" \
  --tiers vram12 --thinking-modes off --extra-flags --reasoning off
run_audit vibethinker-3b f_vt3b \
  --gguf "$M/vibethinker-3b/VibeThinker-3B-Q4_K_M.gguf" \
  --tiers vram12 --thinking-modes on,off

# ─── Era unification: remaining 9 roles for the 4 pre-seed small models ──
ROLES="toolcall,codereview,vision,codegen,recordsqa,longsum,parsejson,visionclass,devplan"
for spec in \
  "qwen35-4b|$M/qwen35-4b/Qwen3.5-4B-Q4_K_M.gguf|$M/qwen35-4b/mmproj-F16.gguf" \
  "qwen35-0_8b|$M/qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf|$M/qwen35-0_8b/mmproj-F16.gguf" \
  "qwen35-2b|$M/qwen35-2b/Qwen3.5-2B-Q4_K_M.gguf|$M/qwen35-2b/mmproj-F16.gguf" \
  "gemma4-e2b|$M/gemma4-e2b-it/gemma-4-E2B-it-Q4_K_M.gguf|$M/gemma4-e2b-it/mmproj-BF16.gguf" ; do
  IFS='|' read -r lbl gguf mmproj <<<"$spec"
  extra=()
  [[ $lbl == gemma* ]] && extra=(--extra-flags --reasoning off)
  log "ERA-BACKFILL $lbl"
  "$PY" "$AUDIT" --label "$lbl" --gguf "$gguf" --mmproj "$mmproj" \
    --tiers cpu --use-recipe --roles "$ROLES" "${extra[@]}" \
    > "$LOGDIR/backfill_$lbl.log" 2>&1
  log "ERA-BACKFILL $lbl exit=$?"
done

# ─── Speed matrix crosses + ctx_max probes ───────────────────────────────
speed() { # label tier gguf extra...
  local lbl=$1 tier=$2 gguf=$3; shift 3
  local roles=speed
  [ "$tier" != cpu ] && roles=speed,ctxprobe
  log "SPEED $lbl $tier (roles=$roles)"
  "$PY" "$AUDIT" --label "$lbl" --gguf "$gguf" --tiers "$tier" \
    --roles "$roles" --thinking-modes none "$@" \
    > "$LOGDIR/speed_${lbl}_${tier}.log" 2>&1
  log "SPEED $lbl $tier exit=$?"
}
# GPU speed + ctx probe for the small models
speed qwen35-0_8b   vram12 "$M/qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf"
speed qwen35-2b     vram12 "$M/qwen35-2b/Qwen3.5-2B-Q4_K_M.gguf"
speed qwen35-4b     vram12 "$M/qwen35-4b/Qwen3.5-4B-Q4_K_M.gguf"
speed gemma4-e2b    vram12 "$M/gemma4-e2b-it/gemma-4-E2B-it-Q4_K_M.gguf" --extra-flags --reasoning off
# ctx probe for the heavies that already have vram12 quality (2 spawns each)
for spec in \
  "bonsai-1bit|$M/bonsai-27b/Bonsai-27B-Q1_0.gguf|--server-bin|$FORK" \
  "gemma4-26b|$M/gemma4-26b-a4b/gemma-4-26B-A4B-it-Q4_K_M.gguf|--moe|on" \
  "qwen3-omni-30b|$M/qwen3-omni-30b/Qwen3-Omni-30B-A3B-Instruct-Q4_K_M.gguf|--moe|on" \
  "qwen36-35b|$M/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf|--moe|on" ; do
  IFS='|' read -r lbl gguf k v <<<"$spec"
  log "CTXPROBE $lbl vram12"
  "$PY" "$AUDIT" --label "$lbl" --gguf "$gguf" --tiers vram12 \
    --use-recipe --roles ctxprobe "$k" "$v" \
    > "$LOGDIR/ctxprobe_$lbl.log" 2>&1
  log "CTXPROBE $lbl exit=$?"
done
# CPU speed for the heavies
speed bonsai-1bit   cpu "$M/bonsai-27b/Bonsai-27B-Q1_0.gguf" --server-bin "$FORK"
speed gemma4-26b    cpu "$M/gemma4-26b-a4b/gemma-4-26B-A4B-it-Q4_K_M.gguf" --moe on --extra-flags --reasoning off
speed qwen3-omni-30b cpu "$M/qwen3-omni-30b/Qwen3-Omni-30B-A3B-Instruct-Q4_K_M.gguf" --moe on
speed nemotron-cascade2-30b cpu "$M/nemotron-cascade2-30b/Nemotron-Cascade-2-30B-A3B-Q4_K_M.gguf" --moe on
speed qwen36-35b    cpu "$M/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf" --moe on
speed bonsai-ternary cpu "$M/bonsai-27b/Ternary-Bonsai-27B-Q2_0.gguf" --server-bin "$FORK"
speed qwen36-27b    cpu "$M/qwen36-27b/Qwen3.6-27B-Q4_K_M.gguf" --moe off

# ─── Restore everything ──────────────────────────────────────────────────
log "=== RESTORE ==="
kill "$JUDGE_PID" 2>/dev/null
sleep 3
bash "$REPO/axi/scripts/axi-game-off" >> "$LOGDIR/driver.log" 2>&1
"$REPO/axi/.venv/bin/python" - <<'PYEOF' >> "$LOGDIR/driver.log" 2>&1
from axi import config
cfg = dict(config._load())
cfg["dev_self_improve_enabled"] = True
config.save(cfg)
print("dev_self_improve_enabled restored to True")
PYEOF
systemctl --user start axi-whisper.service axi-tray.service axi-voice.service
sleep 3
systemctl --user start axi-heartbeat.service
log "=== FINAL MATRIX ==="
"$PY" "$AUDIT" --compare | tee -a "$LOGDIR/driver.log"
log "FINALE COMPLETE"
