#!/bin/bash
# LifeOS Post-Install Verification
# Usage: lifeos-check  (or: life check)
set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

ok()   { echo -e "  ${GREEN}[OK]${NC}   $1"; ((PASS++)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; ((WARN++)); }
info() { echo -e "  ${BLUE}[INFO]${NC} $1"; }

TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
if [[ -z "$TARGET_HOME" ]]; then
    TARGET_HOME="$HOME"
fi

check_life_cmd() {
    local label="$1"
    shift

    local output
    output="$(life "$@" 2>&1)"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        ok "$label"
        return 0
    fi

    if echo "$output" | grep -Eqi "401|unauthorized"; then
        fail "$label (401 Unauthorized)"
    else
        fail "$label (exit ${rc})"
    fi
}

echo -e "${BLUE}${BOLD}"
echo "  LifeOS System Check"
echo "  ==================="
echo -e "${NC}"

# --- Identidad ---
echo -e "${BOLD}Identidad${NC}"
NAME=$(grep -oP '^PRETTY_NAME="\K[^"]+' /etc/os-release 2>/dev/null)
if [[ -n "$NAME" ]] && echo "$NAME" | grep -qi lifeos; then
    ok "OS: $NAME"
else
    fail "os-release no contiene LifeOS (got: ${NAME:-unknown})"
fi

VERSION=$(life --version 2>/dev/null)
if [[ -n "$VERSION" ]]; then
    ok "CLI: $VERSION"
else
    fail "life CLI no encontrado"
fi

VARIANT=$(grep -oP '^VARIANT_ID=\K.*' /etc/os-release 2>/dev/null)
if [[ "$VARIANT" == "lifeos" ]]; then
    ok "Variant: $VARIANT"
else
    warn "VARIANT_ID no es 'lifeos' (got: ${VARIANT:-not set})"
fi
echo

# --- Servicios ---
echo -e "${BOLD}Servicios${NC}"
for svc in lifeosd lifeos-security-baseline; do
    STATE=$(systemctl is-active "$svc" 2>/dev/null)
    case "$STATE" in
        active)  ok "$svc: active" ;;
        *)       fail "$svc: $STATE" ;;
    esac
done

# llama-server es especial - puede tardar en cargar el modelo
LLAMA_STATE=$(systemctl is-active llama-server 2>/dev/null)
LLAMA_ENABLED=$(systemctl is-enabled llama-server 2>/dev/null)
case "$LLAMA_STATE" in
    active)
        ok "llama-server: active"
        ;;
    activating|inactive)
        warn "llama-server: $LLAMA_STATE (puede estar iniciando)"
        ;;
    failed)
        warn "llama-server: failed (ejecuta 'journalctl -u llama-server' para ver logs)"
        ;;
    *)
        fail "llama-server: $LLAMA_STATE"
        ;;
esac
echo

# --- Unidades fallidas ---
echo -e "${BOLD}Unidades fallidas${NC}"
FAILED_UNITS=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
if [[ -z "$FAILED_UNITS" ]]; then
    ok "Sin unidades fallidas en systemd"
else
    if echo "$FAILED_UNITS" | grep -qx "lifeos-first-boot.service"; then
        fail "lifeos-first-boot.service falló"
    elif echo "$FAILED_UNITS" | grep -q "lifeos-first-boot.service"; then
        fail "lifeos-first-boot.service falló"
    fi

    if echo "$FAILED_UNITS" | grep -q "systemd-remount-fs.service"; then
        info "systemd-remount-fs.service falló (conocido en Fedora bootc + VirtualBox)"
    fi

    OTHER_FAILED=$(echo "$FAILED_UNITS" | grep -Ev '^(lifeos-first-boot\.service|systemd-remount-fs\.service)$' || true)
    if [[ -n "$OTHER_FAILED" ]]; then
        warn "Otras unidades fallidas detectadas: $(echo "$OTHER_FAILED" | tr '\n' ' ')"
    fi
fi
echo

# --- AI Runtime ---
echo -e "${BOLD}AI Runtime${NC}"
LLAMA_PATH=$(which llama-server 2>/dev/null)
# Also check /usr/sbin which may not be in unprivileged PATH
if [[ -z "$LLAMA_PATH" ]] && [[ -x /usr/sbin/llama-server ]]; then
    LLAMA_PATH="/usr/sbin/llama-server"
fi
if [[ -n "$LLAMA_PATH" ]]; then
    ok "Binary: $LLAMA_PATH"
else
    fail "llama-server no encontrado en PATH ni en /usr/sbin"
fi

LLAMA_VER=$("${LLAMA_PATH:-llama-server}" --version 2>&1 | head -1)
if [[ -n "$LLAMA_VER" ]]; then
    ok "Version: $LLAMA_VER"
else
    fail "llama-server --version falló"
fi

MODEL_ENV=$(grep -oP '^LIFEOS_AI_MODEL=\K.*' /etc/lifeos/llama-server.env 2>/dev/null)
MODEL_PATH="/var/lib/lifeos/models/${MODEL_ENV}"
if [[ -f "$MODEL_PATH" ]]; then
    MODEL_SIZE=$(du -h "$MODEL_PATH" | cut -f1)
    ok "Model: $MODEL_ENV ($MODEL_SIZE)"
else
    fail "Model no encontrado: ${MODEL_ENV:-not configured} (expected at $MODEL_PATH)"
fi

# Check if llama-server is listening
if curl -sf http://127.0.0.1:8082/health >/dev/null 2>&1; then
    ok "API: listening on :8082"
else
    warn "API: no responde en :8082 (servicio puede estar iniciando)"
fi
echo

# --- bootc ---
echo -e "${BOLD}bootc${NC}"
if command -v bootc &>/dev/null; then
    BOOTC_IMG=$(sudo bootc status --json 2>/dev/null | grep -oP '"image":\s*"\K[^"]+' | head -1)
    if [[ -n "$BOOTC_IMG" ]]; then
        ok "Booted: $BOOTC_IMG"
    else
        warn "bootc disponible pero no se pudo leer status (necesita sudo)"
    fi
else
    fail "bootc no encontrado"
fi
echo

# --- Daemon (lifeosd) ---
echo -e "${BOLD}Daemon${NC}"
TOKEN=$(sudo cat /run/lifeos/bootstrap.token 2>/dev/null)
if [[ -n "$TOKEN" ]]; then
    ok "Bootstrap token: presente"
    HEALTH=$(curl -sf -H "x-bootstrap-token: $TOKEN" http://127.0.0.1:8081/api/v1/health 2>/dev/null)
    if [[ -n "$HEALTH" ]]; then
        ok "Health API: responde"
    else
        warn "Health API: no responde en :8081"
    fi
else
    warn "Bootstrap token: no disponible (necesita sudo)"
fi
echo

# --- CLI Fase 0/1 ---
echo -e "${BOLD}CLI Fase 0/1${NC}"
check_life_cmd "help" --help
check_life_cmd "status" status
check_life_cmd "mode list" mode list
check_life_cmd "mode show" mode show
check_life_cmd "context status" context status
check_life_cmd "context list" context list
check_life_cmd "telemetry stats" telemetry stats
check_life_cmd "telemetry consent" telemetry consent
check_life_cmd "overlay status" overlay status
check_life_cmd "follow-along status" follow-along status
check_life_cmd "ai status" ai status
check_life_cmd "update status" update status
echo

# --- CLI Fase 2 ---
echo -e "${BOLD}CLI Fase 2${NC}"
check_life_cmd "intents mode status" intents mode status
check_life_cmd "intents team-runs" intents team-runs --limit 1
check_life_cmd "intents log" intents log --limit 1
check_life_cmd "id list" id list --active
check_life_cmd "workspace list" workspace list --limit 5
check_life_cmd "onboarding trust-mode status" onboarding trust-mode status
check_life_cmd "memory stats" memory stats
check_life_cmd "memory list" memory list --limit 1
check_life_cmd "permissions show" permissions show
check_life_cmd "sync status" sync status
check_life_cmd "skills list" skills list
check_life_cmd "agents list" agents list --active
check_life_cmd "soul merge" soul merge --workplace base
check_life_cmd "mesh list" mesh list --active
check_life_cmd "browser audit" browser audit --limit 1
check_life_cmd "computer-use status" computer-use status
check_life_cmd "workflow help" workflow --help
check_life_cmd "portal status" portal status
check_life_cmd "lab status" lab status --json
echo

# --- Hardware Fase 2 ---
echo -e "${BOLD}Hardware Fase 2${NC}"
GPU_LINES=$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)
HAS_NVIDIA=0
HAS_AMD=0
HAS_INTEL=0

if [[ -n "$GPU_LINES" ]]; then
    GPU_COUNT=$(echo "$GPU_LINES" | wc -l | tr -d ' ')
    ok "Adaptadores GPU detectados: $GPU_COUNT"
else
    warn "No se detectaron adaptadores GPU por lspci"
fi

if echo "$GPU_LINES" | grep -Eqi 'nvidia'; then HAS_NVIDIA=1; fi
if echo "$GPU_LINES" | grep -Eqi 'amd|advanced micro devices|radeon'; then HAS_AMD=1; fi
if echo "$GPU_LINES" | grep -Eqi 'intel'; then HAS_INTEL=1; fi

if [[ $HAS_NVIDIA -eq 1 ]]; then
    if command -v nvidia-smi &>/dev/null; then
        if nvidia-smi -L >/dev/null 2>&1; then
            ok "NVIDIA stack: nvidia-smi operativo"
        else
            fail "NVIDIA stack: nvidia-smi no operativo"
        fi
    else
        fail "GPU NVIDIA detectada pero nvidia-smi no encontrado"
    fi

    if lsmod 2>/dev/null | grep -q '^nvidia'; then
        ok "Modulo kernel nvidia: cargado"
    else
        warn "Modulo kernel nvidia no cargado"
    fi
fi

if [[ $HAS_AMD -eq 1 ]]; then
    if command -v rocminfo &>/dev/null; then
        if rocminfo >/dev/null 2>&1; then
            ok "AMD stack: rocminfo operativo"
        else
            warn "AMD stack: rocminfo instalado pero no operativo (fallback posible)"
        fi
    else
        info "rocminfo no instalado (AMD puede usar fallback Vulkan/CPU)"
    fi
fi

if [[ $HAS_INTEL -eq 1 ]] && ([[ $HAS_NVIDIA -eq 1 ]] || [[ $HAS_AMD -eq 1 ]]); then
    ok "Topologia GPU hibrida detectada (iGPU + dGPU)"
    if command -v supergfxctl &>/dev/null; then
        if supergfxctl -g >/dev/null 2>&1; then
            ok "supergfxctl disponible y responde"
        else
            warn "supergfxctl presente pero no responde"
        fi
    else
        warn "supergfxctl no encontrado (switching hibrido limitado)"
    fi
else
    info "Topologia hibrida no detectada"
fi

if compgen -G "/sys/class/drm/card*-*/modes" >/dev/null; then
    HIGH_REFRESH_MODE=$(grep -hE '[0-9]{3,4}x[0-9]{3,4}.*(120|144|165|240)' /sys/class/drm/card*-*/modes 2>/dev/null | head -1 || true)
    if [[ -n "$HIGH_REFRESH_MODE" ]]; then
        ok "Modo high-refresh detectado (${HIGH_REFRESH_MODE})"
    else
        warn "No se detectaron modos >=120Hz en DRM"
    fi
else
    warn "No se pudieron leer modos DRM"
fi

if compgen -G "/sys/class/drm/card*-*/vrr_capable" >/dev/null; then
    if grep -q '^1$' /sys/class/drm/card*-*/vrr_capable 2>/dev/null; then
        ok "VRR/Adaptive-Sync reportado por DRM"
    else
        warn "VRR/Adaptive-Sync no reportado por DRM"
    fi
else
    info "VRR no expuesto por este stack DRM"
fi

if command -v flatpak &>/dev/null; then
    if flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
        ok "Steam Flatpak instalado"
        if flatpak list --columns=application 2>/dev/null | grep -Eqi 'Steam\.CompatibilityTool\.Proton'; then
            ok "Proton runtime detectado (Flatpak)"
        elif find "$TARGET_HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/common" -maxdepth 1 -type d -iname 'Proton*' 2>/dev/null | grep -q .; then
            ok "Proton detectado en libreria de Steam"
        else
            warn "Proton no detectado aun (se descarga con juegos compatibles)"
        fi
    else
        warn "Steam Flatpak no instalado"
    fi
else
    warn "flatpak no encontrado"
fi

check_life_cmd "ai profile" ai profile
check_life_cmd "telemetry snapshot" telemetry snapshot
echo

# --- Disco ---
echo -e "${BOLD}Disco${NC}"
DISK_INFO=$(df -h /var 2>/dev/null | tail -1)
DISK_USE=$(echo "$DISK_INFO" | awk '{print $5}' | tr -d '%')
DISK_AVAIL=$(echo "$DISK_INFO" | awk '{print $4}')
if [[ -n "$DISK_USE" ]] && [[ "$DISK_USE" -lt 90 ]]; then
    ok "/var: ${DISK_USE}% usado (${DISK_AVAIL} libre)"
elif [[ -n "$DISK_USE" ]]; then
    warn "/var: ${DISK_USE}% usado (${DISK_AVAIL} libre)"
else
    warn "No se pudo leer uso de disco"
fi
echo

# --- Red ---
echo -e "${BOLD}Red${NC}"
IP=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
if [[ -n "$IP" ]]; then
    ok "IP: $IP"
else
    warn "Sin IP global asignada"
fi
echo

# --- Resumen ---
echo -e "${BOLD}Resumen${NC}"
TOTAL=$((PASS + FAIL + WARN))
echo -e "  ${GREEN}$PASS passed${NC}  ${RED}$FAIL failed${NC}  ${YELLOW}$WARN warnings${NC}  ($TOTAL checks)"
echo

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}Sistema OK${NC}"
else
    echo -e "  ${RED}${BOLD}$FAIL problemas detectados${NC}"
fi
echo

exit $FAIL
