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
        warn "systemd-remount-fs.service falló (conocido en Fedora bootc + VirtualBox)"
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
