#!/usr/bin/env bash
#
# LifeOS / Axi — installer for Arch-based Linux (reference target: CachyOS).
#
# Idempotent: re-running only does the work that is still missing. Safe to
# interrupt and resume. Nothing is downloaded or installed without telling
# you first; the 22 GB language model always asks for explicit consent.
#
# Usage:
#   ./install.sh              full install (interactive consent for big steps)
#   ./install.sh --check      verify the system, change nothing, exit
#   ./install.sh --yes        assume "yes" to every prompt (CI / unattended)
#   ./install.sh --skip-models   install software + services, no model downloads
#   ./install.sh --skip-aur      do not touch AUR packages
#   ./install.sh -h | --help
#
# Requirements: an Arch-based system (pacman), an NVIDIA GPU with CUDA for the
# brain model, and ~35 GB free disk if you pull every model.

set -euo pipefail

# ---------------------------------------------------------------------------
# Layout — the systemd units reference %h/LifeOS/lifeos, so the repository
# MUST live at ~/LifeOS/lifeos for the services to find the venv and scripts.
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_DIR="$HOME/LifeOS/lifeos"
MODELS_DIR="$HOME/LifeOS/models"
VENV="$REPO_DIR/axi/.venv"
HF="$VENV/bin/hf"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
LifeOS / Axi — installer for Arch-based Linux (reference target: CachyOS).

Idempotent: re-running only does the work that is still missing. Nothing is
installed or downloaded without telling you first; the 22 GB language model
always asks for explicit consent.

Usage:
  ./install.sh                 full install (interactive consent for big steps)
  ./install.sh --check         verify the system, change nothing, exit
  ./install.sh --yes           assume "yes" to every prompt (CI / unattended)
  ./install.sh --skip-models   install software + services, no model downloads
  ./install.sh --skip-aur      do not touch AUR packages
  ./install.sh -h | --help

Requirements: an Arch-based system (pacman), an NVIDIA GPU with CUDA for the
brain model, and ~35 GB free disk if you pull every model.
EOF
}

CHECK_ONLY=0
ASSUME_YES=0
SKIP_MODELS=0
SKIP_AUR=0
for arg in "$@"; do
  case "$arg" in
    --check)       CHECK_ONLY=1 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --skip-models) SKIP_MODELS=1 ;;
    --skip-aur)    SKIP_AUR=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown flag: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  RED=$'\033[31m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; GREEN=''; YELLOW=''; RED=''; BLUE=''; RESET=''
fi
step() { printf "\n%s==>%s %s%s%s\n" "$BLUE" "$RESET" "$BOLD" "$1" "$RESET"; }
ok()   { printf "  %s✓%s %s\n" "$GREEN" "$RESET" "$1"; }
warn() { printf "  %s!%s %s\n" "$YELLOW" "$RESET" "$1"; }
err()  { printf "  %s✗%s %s\n" "$RED" "$RESET" "$1" >&2; }
die()  { err "$1"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Ask a yes/no question. Honors --yes. Default is "no" unless $2 == "yes".
ask() {
  local prompt="$1" default="${2:-no}" reply
  if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
  local hint="[y/N]"; [ "$default" = "yes" ] && hint="[Y/n]"
  printf "  %s?%s %s %s " "$YELLOW" "$RESET" "$prompt" "$hint"
  read -r reply || reply=""
  reply="${reply:-$default}"
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  step "Preflight"

  have pacman || die "This installer targets Arch-based distributions (pacman not found)."
  ok "pacman present"

  local distro_id="" distro_like=""
  if [ -r /etc/os-release ]; then
    distro_id="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
    distro_like="$(. /etc/os-release 2>/dev/null && echo "${ID_LIKE:-}")"
  fi
  if [ "$distro_id" = "cachyos" ]; then
    ok "CachyOS detected (reference platform)"
  elif [ "$distro_id" = "arch" ] || [[ "$distro_like" == *arch* ]]; then
    warn "Arch-based ($distro_id) — should work, but CachyOS is the only tested target."
  else
    warn "Unrecognized distro ($distro_id) — pacman is present, continuing anyway."
  fi

  if [ "$REPO_DIR" != "$EXPECTED_DIR" ]; then
    err "Repository is at: $REPO_DIR"
    err "It MUST be cloned to: $EXPECTED_DIR"
    err "The systemd services reference \$HOME/LifeOS/lifeos. Move it and re-run:"
    err "    mkdir -p \"\$HOME/LifeOS\" && mv \"$REPO_DIR\" \"$EXPECTED_DIR\""
    exit 1
  fi
  ok "repository location: $REPO_DIR"

  if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
    ok "NVIDIA GPU available"
  else
    warn "No working NVIDIA GPU detected — the brain model runs on GPU; it will not start without one."
  fi
}

# ---------------------------------------------------------------------------
# pacman packages
# ---------------------------------------------------------------------------
PACMAN_PKGS=(
  git base-devel openssl
  ffmpeg portaudio libnotify wl-clipboard
  pipewire
  tesseract tesseract-data-eng tesseract-data-spa
  cuda nvidia-utils
  kde-cli-tools
  ydotool
)

install_pacman() {
  step "System packages (pacman)"
  local missing=()
  for p in "${PACMAN_PKGS[@]}"; do
    if pacman -Qq "$p" >/dev/null 2>&1; then
      ok "$p"
    else
      missing+=("$p")
    fi
  done
  if [ ${#missing[@]} -eq 0 ]; then
    ok "all system packages already installed"
    return
  fi
  warn "missing: ${missing[*]}"
  if ask "Install ${#missing[@]} package(s) via sudo pacman -S --needed?" yes; then
    local pacman_args=(-S --needed)
    [ "$ASSUME_YES" -eq 1 ] && pacman_args+=(--noconfirm)
    sudo pacman "${pacman_args[@]}" "${missing[@]}"
  else
    warn "skipped — the system may not be fully functional"
  fi
}

# ---------------------------------------------------------------------------
# AUR packages (not in official repos)
# ---------------------------------------------------------------------------
detect_aur_helper() {
  if have yay; then echo yay
  elif have paru; then echo paru
  else echo ""; fi
}

install_aur() {
  step "AUR packages"
  if [ "$SKIP_AUR" -eq 1 ]; then warn "--skip-aur: skipping"; return; fi

  # repo-or-binary checks, not just package names: llama.cpp-cuda provides
  # /usr/bin/llama-server, piper-tts-bin provides /usr/bin/piper-tts.
  local need=()
  have llama-server || need+=("llama.cpp-cuda")
  have piper-tts    || need+=("piper-tts-bin")

  if [ ${#need[@]} -eq 0 ]; then
    ok "llama-server and piper-tts already present"
    return
  fi

  local helper; helper="$(detect_aur_helper)"
  if [ -z "$helper" ]; then
    err "Need an AUR helper (yay or paru) to install: ${need[*]}"
    err "Install one first, e.g.:"
    err "    sudo pacman -S --needed git base-devel"
    err "    git clone https://aur.archlinux.org/paru.git && cd paru && makepkg -si"
    exit 1
  fi
  ok "AUR helper: $helper"
  warn "missing: ${need[*]} (llama.cpp-cuda may take a while to build)"
  if ask "Install with $helper?" yes; then
    local helper_args=(-S --needed)
    [ "$ASSUME_YES" -eq 1 ] && helper_args+=(--noconfirm)
    "$helper" "${helper_args[@]}" "${need[@]}"
  else
    warn "skipped — voice/brain features will not work without these"
  fi
}

# ---------------------------------------------------------------------------
# uv + Python environment
# ---------------------------------------------------------------------------
install_uv() {
  step "uv (Python toolchain)"
  if have uv; then ok "uv present"; return; fi
  if [ -x "$HOME/.local/bin/uv" ]; then ok "uv present (~/.local/bin)"; export PATH="$HOME/.local/bin:$PATH"; return; fi
  warn "uv not found"
  if ask "Bootstrap uv from astral.sh?" yes; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    have uv || die "uv install failed"
    ok "uv installed"
  else
    die "uv is required to build the Python environment"
  fi
}

sync_python() {
  step "Python environment (uv sync)"
  # axi depends on lifeos as an editable path dep, so a single sync in axi/
  # installs both packages into axi/.venv (Python pinned to 3.12).
  ( cd "$REPO_DIR/axi" && uv sync )
  [ -x "$VENV/bin/python" ] || die "venv not created at $VENV"
  ok "axi + lifeos installed into $VENV"
}

# ---------------------------------------------------------------------------
# Environment file (optional Hugging Face token for gated models)
# ---------------------------------------------------------------------------
setup_env() {
  step "Environment file"
  local env_file="$REPO_DIR/axi/.env"
  if [ -f "$env_file" ]; then ok ".env already exists"; return; fi
  cat > "$env_file" <<'EOF'
# Hugging Face token — only needed if you enable speaker diarization
# (pyannote models are gated). The default models (brain, nano, piper,
# whisper) are public and download without a token.
# Create one at https://huggingface.co/settings/tokens
# HF_TOKEN=hf_xxx
EOF
  ok "wrote $env_file (HF_TOKEN commented out — optional)"
}

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------
# hf_get <repo> <repo_path> <dest_dir>
# Downloads a single file and ends with it at <dest_dir>/<basename>, flattening
# any repo subdirectories. Skips if already present.
hf_get() {
  local repo="$1" rpath="$2" dest="$3"
  local base; base="$(basename "$rpath")"
  if [ -f "$dest/$base" ]; then ok "$base (already present)"; return; fi
  mkdir -p "$dest"
  [ -n "${HF_TOKEN:-}" ] && export HF_TOKEN
  "$HF" download "$repo" "$rpath" --local-dir "$dest" >/dev/null
  # If the repo path had subdirs, hoist the file to the flat dest.
  if [ "$rpath" != "$base" ] && [ -f "$dest/$rpath" ]; then
    mv "$dest/$rpath" "$dest/$base"
    # remove now-empty leading dir of the repo path
    rm -rf "${dest:?}/${rpath%%/*}"
  fi
  ok "$base"
}

# ---------------------------------------------------------------------------
# Brain model — hardware-aware automatic selection.
#
# Detects VRAM/RAM, picks the best-fitting catalog model + tuned llama-server
# params, tells the user what was detected + chosen, downloads THAT model (with
# consent for the large MoE brain), and writes the tuned config the launcher
# reads (active_model.json + per-model overrides). Advanced override:
#   AXI_BRAIN_MODEL=<catalog-id> ./install.sh
# ---------------------------------------------------------------------------
download_brain() {
  local py="$VENV/bin/python"
  [ -x "$py" ] || die "venv python missing at $py"

  # Machine-readable recommendation (honors AXI_BRAIN_MODEL).
  local rec_json
  if ! rec_json="$(cd "$REPO_DIR/axi" && "$py" -m axi.install_brain --json 2>/dev/null)"; then
    warn "brain auto-detection failed — skipping brain model selection"
    return
  fi

  # Human report (detected → chosen → tuned params).
  (cd "$REPO_DIR/axi" && "$py" -m axi.install_brain --report) | while IFS= read -r line; do
    ok "$line"
  done

  # Parse the JSON plan with python (no jq dependency). Emits, per file:
  #   <repo_id>\t<filename>\t<kind>
  # plus a leading header line: MODEL\t<model_id>\t<dir>\t<local>\t<size_hint>
  local plan
  plan="$("$py" - "$rec_json" <<'PY'
import json, sys
rec = json.loads(sys.argv[1])
local = "1" if rec.get("local") else "0"
# Rough on-disk size hint for the consent prompt.
size = "~22 GB" if rec["model_id"] == "qwen36-35b-a3b" else "a few GB"
print(f"MODEL\t{rec['model_id']}\t{rec['dir']}\t{local}\t{size}")
for f in rec["files"]:
    print(f"{f['repo_id']}\t{f['filename']}\t{f['kind']}")
PY
)"

  local model_id model_dir is_local size_hint
  model_id="$(printf '%s\n' "$plan" | awk -F'\t' '$1=="MODEL"{print $2}')"
  model_dir="$(printf '%s\n' "$plan" | awk -F'\t' '$1=="MODEL"{print $3}')"
  is_local="$(printf '%s\n' "$plan" | awk -F'\t' '$1=="MODEL"{print $4}')"
  size_hint="$(printf '%s\n' "$plan" | awk -F'\t' '$1=="MODEL"{print $5}')"
  local dest="$MODELS_DIR/$model_dir"

  if [ "$is_local" = "1" ]; then
    # Legacy/local bundle (the Qwen3.6 MoE brain). Files ship with the original
    # install; if present we just activate, otherwise pull from the known repo.
    if [ -f "$dest/Qwen3.6-35B-A3B-MXFP4_MOE.gguf" ]; then
      ok "brain model already present"
    else
      warn "Brain model: $model_id ($size_hint on disk). MoE with --cpu-moe offload."
      if ask "Download the brain model now ($size_hint)?"; then
        hf_get unsloth/Qwen3.6-35B-A3B-GGUF Qwen3.6-35B-A3B-MXFP4_MOE.gguf "$dest"
        hf_get unsloth/Qwen3.6-35B-A3B-GGUF mmproj-BF16.gguf "$dest"
      else
        warn "skipped — llama-server.service will not start until this model exists"
        return
      fi
    fi
  else
    # Catalog model with real HF repos. Download every bundle file.
    local first_gguf
    first_gguf="$(printf '%s\n' "$plan" | awk -F'\t' '$3=="gguf"{print $2; exit}')"
    if [ -n "$first_gguf" ] && [ -f "$dest/$first_gguf" ]; then
      ok "brain model already present ($model_id)"
    else
      warn "Brain model: $model_id ($size_hint on disk), tuned for your hardware."
      if ask "Download the recommended brain model now ($size_hint)?"; then
        printf '%s\n' "$plan" | while IFS=$'\t' read -r repo fname kind; do
          [ "$repo" = "MODEL" ] && continue
          [ -z "$repo" ] && continue
          hf_get "$repo" "$fname" "$dest"
        done
      else
        warn "skipped — llama-server.service will not start until a brain model exists"
        return
      fi
    fi
  fi

  # Write the tuned config (active_model.json + per-model overrides) so the
  # launcher uses the hardware-matched params. No restart during install.
  if (cd "$REPO_DIR/axi" && "$py" -m axi.install_brain --write-config >/dev/null); then
    ok "wrote tuned brain config for $model_id (active_model.json)"
  else
    warn "could not write tuned brain config — defaults will apply"
  fi
}

download_models() {
  step "Models"
  if [ "$SKIP_MODELS" -eq 1 ]; then warn "--skip-models: skipping all downloads"; return; fi
  [ -x "$HF" ] || die "hf CLI missing — run the Python sync step first"

  # --- Brain (required, large) — hardware-aware automatic selection ------
  # Detect VRAM/RAM and pick the best-fitting catalog model + tuned params,
  # so a fresh install ends up with the right brain for THIS machine with no
  # manual decision. An advanced user can override with AXI_BRAIN_MODEL=<id>.
  download_brain

  # --- Nano (optional) — catalog-driven ------------------------------------
  # The active nano model is read from active_nano_model.json (or falls back
  # to the default Qwen3.5-0.8B). Override with AXI_NANO_MODEL=<catalog-id>.
  local py="$VENV/bin/python"
  local nano_plan
  nano_plan="$("$py" - <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "axi", "src"))
try:
    from axi.nano_catalog import by_id, catalog
except ImportError:
    # Fallback: default entry description if the package is not yet installed.
    print("qwen35-0_8b\tunsloth/Qwen3.5-0.8B-GGUF\tQwen3.5-0.8B-Q4_K_M.gguf\tgguf")
    print("qwen35-0_8b\tunsloth/Qwen3.5-0.8B-GGUF\tmmproj-F16.gguf\tmmproj")
    sys.exit(0)

override = os.environ.get("AXI_NANO_MODEL", "").strip()
entry = by_id(override) if override else None
if entry is None:
    entry = catalog()[0]  # default: qwen35-0_8b

# Emit: <entry_id> TAB <repo_id> TAB <filename> TAB <kind>
for f in entry.files:
    print(f"{entry.id}\t{f.repo_id}\t{f.filename}\t{f.kind}")
PY
)"

  # Parse the plan. Each line: <entry_id> TAB <repo_id> TAB <filename> TAB <kind>
  local nano_id nano_dest first_gguf
  nano_id="$(printf '%s\n' "$nano_plan" | awk -F'\t' 'NR==1{print $1}')"
  nano_dest="$MODELS_DIR/$nano_id"
  first_gguf="$(printf '%s\n' "$nano_plan" | awk -F'\t' '$4=="gguf"{print $3; exit}')"

  if [ -n "$first_gguf" ] && [ -f "$nano_dest/$first_gguf" ]; then
    ok "nano model already present ($nano_id)"
  elif ask "Download the optional nano model $nano_id (~750 MB)?"; then
    printf '%s\n' "$nano_plan" | while IFS=$'\t' read -r _id repo fname _kind; do
      [ -z "$repo" ] && continue
      hf_get "$repo" "$fname" "$nano_dest"
    done
    ok "nano model downloaded: $nano_id"
    # Write the active config so the launcher knows which model to use.
    if (cd "$REPO_DIR/axi" && "$py" -m axi.install_nano --write-config >/dev/null 2>&1); then
      ok "wrote nano config (active_nano_model.json)"
    else
      warn "could not write nano config — defaults will apply on first launch"
    fi
  else
    warn "skipped nano model (llama-nano.service stays optional)"
  fi

  # --- Piper TTS voice (required for spoken replies) ----------------------
  local piper_dir="$MODELS_DIR/piper-voices/es_MX-claude"
  if [ -f "$piper_dir/es_MX-claude-high.onnx" ]; then
    ok "piper voice already present"
  else
    hf_get rhasspy/piper-voices es/es_MX/claude/high/es_MX-claude-high.onnx "$piper_dir"
    hf_get rhasspy/piper-voices es/es_MX/claude/high/es_MX-claude-high.onnx.json "$piper_dir"
  fi

  # --- Whisper (auto-downloads on first transcription) -------------------
  ok "whisper large-v3-turbo: downloads automatically on first use"

  # --- Personal voice-clone reference (cannot be provided) ---------------
  if [ ! -f "$MODELS_DIR/voices/hector-reference.wav" ]; then
    warn "Optional: ~/LifeOS/models/voices/hector-reference.wav is a personal"
    warn "voice-clone reference (for XTTS). It is not shipped; voice cloning is"
    warn "disabled until you record one. Everything else works without it."
  fi
}

# ---------------------------------------------------------------------------
# input group — needed for ydotool to open /dev/uinput
# ---------------------------------------------------------------------------
setup_input_group() {
  step "input group + uinput (ydotool /dev/uinput access)"
  # ydotoold needs the uinput kernel module and /dev/uinput; on a fresh system
  # the module is often not loaded, so ydotoold gets stuck "activating" with no
  # socket. Ensure it loads now and on every boot.
  if [ ! -f /etc/modules-load.d/uinput.conf ]; then
    echo uinput | sudo tee /etc/modules-load.d/uinput.conf >/dev/null
    ok "uinput will load on boot (/etc/modules-load.d/uinput.conf)"
  fi
  if [ ! -e /dev/uinput ]; then
    sudo modprobe uinput 2>/dev/null && ok "loaded uinput module" \
      || warn "could not load uinput now — it will load on next boot"
  fi
  if id -nG | grep -qw input; then
    ok "$USER is already in the 'input' group"
  else
    warn "Adding $USER to the 'input' group (needed for ydotool). Reboot (or log out and back in) for it to take effect."
    sudo usermod -aG input "$USER"
    ok "added $USER to 'input' group"
  fi
  # ydotool ships /usr/lib/udev/rules.d/80-uinput.rules (sets /dev/uinput to
  # input:0660), but a freshly installed rule only applies to the existing
  # device after a udev reload + re-trigger; without this /dev/uinput stays
  # 0600 root:root and ydotoold cannot open it until a reboot.
  sudo udevadm control --reload-rules 2>/dev/null || true
  sudo udevadm trigger --name-match=uinput 2>/dev/null || true
  # The udev rule applies /dev/uinput's input:0660 perms via a static node at
  # BOOT (systemd-tmpfiles); a runtime trigger does not re-apply it. Set the
  # perms directly now too, so ydotoold can open /dev/uinput without a reboot.
  if [ -e /dev/uinput ]; then
    sudo chgrp input /dev/uinput 2>/dev/null && sudo chmod 0660 /dev/uinput 2>/dev/null \
      && ok "/dev/uinput set to input:0660" \
      || warn "could not set /dev/uinput perms now — a reboot will apply them"
  fi
}

# ---------------------------------------------------------------------------
# systemd user services
# ---------------------------------------------------------------------------
# Services that never need a model and are always safe to enable.
SERVICES_BASE=(ydotoold.service axi-tray.service axi-dashboard.service axi-voice.service axi-whisper.service)

install_services() {
  step "systemd user services"
  mkdir -p "$SYSTEMD_USER_DIR"

  # Symlink every unit so repo edits propagate; enable the safe set now and
  # the model-dependent ones only when their model is present.
  local unit
  for unit in "$REPO_DIR"/axi/systemd/*.service; do
    ln -sf "$unit" "$SYSTEMD_USER_DIR/$(basename "$unit")"
  done
  ok "linked $(ls "$REPO_DIR"/axi/systemd/*.service | wc -l | tr -d ' ') unit(s) into $SYSTEMD_USER_DIR"

  systemctl --user daemon-reload

  # Re-apply changed unit definitions to services that are already running.
  # A daemon-reload alone does NOT restart a live unit whose ExecStart changed
  # (e.g. an upgraded llama-nano context window), silently leaving the old
  # command running — the "stale unit" trap. try-restart is a no-op for
  # inactive units, so this only touches services that are currently up.
  for unit in "$REPO_DIR"/axi/systemd/*.service; do
    systemctl --user try-restart "$(basename "$unit")" 2>/dev/null || true
  done

  local to_enable=("${SERVICES_BASE[@]}")
  [ -f "$MODELS_DIR/Qwen3.6-35B-A3B/Qwen3.6-35B-A3B-MXFP4_MOE.gguf" ] && to_enable+=(llama-server.service)
  # Check if the active nano model gguf is present; fall back to the default.
  local nano_gguf
  nano_gguf="$("$VENV/bin/python" - <<'PY' 2>/dev/null
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "axi", "src"))
try:
    from axi import nano_manager
    data = nano_manager.read_active_nano() or nano_manager.DEFAULT_NANO
    print(data.get("gguf", ""))
except Exception:
    # Absolute fallback: historical default path.
    print(str(Path.home() / "LifeOS/models/qwen35-0_8b/Qwen3.5-0.8B-Q4_K_M.gguf"))
PY
)"
  [ -n "$nano_gguf" ] && [ -f "$nano_gguf" ] && to_enable+=(llama-nano.service)

  if ask "Enable and start ${#to_enable[@]} service(s) now?" yes; then
    systemctl --user enable --now "${to_enable[@]}"
    ok "enabled: ${to_enable[*]}"
  else
    warn "skipped — enable later with: systemctl --user enable --now ${to_enable[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
run_doctor() {
  step "Health check (axi-doctor)"
  if [ -x "$VENV/bin/python" ]; then
    if ( cd "$REPO_DIR/axi" && "$VENV/bin/python" -m axi.doctor ); then
      return 0
    fi
    warn "doctor reported issues — review above (a fresh install may need services to warm up first)"
    return 1
  fi
  warn "venv not ready — skipping doctor"
  return 1
}

print_next_steps() {
  step "Done"
  cat <<EOF
  ${BOLD}Next steps${RESET}
  1. Bind a global shortcut to start/stop voice capture:
       KDE → System Settings → Shortcuts → Custom → Command/URL
       Command: ${REPO_DIR}/axi/scripts/axi-toggle   (suggested: Super+Space)
  2. Open the dashboard:
       http://127.0.0.1:8081   (axi-dashboard.service)
  3. Re-check health any time:
       ${REPO_DIR}/axi/scripts/axi-check
       ./install.sh --check
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  printf "%s%sLifeOS / Axi installer%s\n" "$BOLD" "$BLUE" "$RESET"

  if [ "$CHECK_ONLY" -eq 1 ]; then
    preflight
    if run_doctor; then exit 0; else exit 1; fi
  fi

  preflight
  install_pacman
  install_aur
  setup_input_group
  install_uv
  sync_python
  setup_env
  download_models
  install_services
  run_doctor || true
  print_next_steps
}

main "$@"
