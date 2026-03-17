#!/usr/bin/env bash
# LifeOS audio route self-heal.
# Repairs default sink/source when PipeWire/WirePlumber restarts or device IDs change.
set -euo pipefail
BT_HFP_UNSTABLE=0

log() {
    echo "[lifeos-audio-heal] $*" >&2
}

list_sinks() {
    pactl list short sinks | awk '{print $2}' | grep -Ev '^(auto_null)$' || true
}

list_sources() {
    pactl list short sources | awk '{print $2}' | grep -Ev '(^auto_null\.monitor$|\.monitor$)' || true
}

extract_card_block() {
    local card_name="$1"
    pactl list cards | awk -v card="${card_name}" '
        BEGIN { in_card=0 }
        /^[[:space:]]*(Card|Tarjeta) #[0-9]+/ { in_card=0 }
        /^[[:space:]]*(Name|Nombre): / {
            line=$0
            sub(/^[[:space:]]*(Name|Nombre): /, "", line)
            if (line == card) {
                in_card=1
                print
                next
            }
        }
        in_card { print }
    '
}

ensure_bluetooth_cards_a2dp() {
    local bt_cards bt_card card_block active_profile
    bt_cards="$(pactl list cards short | awk '$2 ~ /^bluez_card\./ {print $2}')"
    if [ -z "${bt_cards}" ]; then
        return 0
    fi

    for bt_card in ${bt_cards}; do
        card_block="$(extract_card_block "${bt_card}")"
        if ! printf '%s\n' "${card_block}" | grep -q 'a2dp-sink'; then
            if printf '%s\n' "${card_block}" | awk -F': ' '/Active Profile:|Perfil Activo:/{print $2; exit}' | grep -Eq '^headset-head-unit(-cvsd)?$'; then
                BT_HFP_UNSTABLE=1
                log "Detected ${bt_card} in HFP/HSP without A2DP profile; will avoid Bluetooth sink fallback"
            fi
            continue
        fi

        active_profile="$(printf '%s\n' "${card_block}" | awk -F': ' '/Active Profile:|Perfil Activo:/{print $2; exit}')"
        if printf '%s\n' "${active_profile}" | grep -Eq '^headset-head-unit(-cvsd)?$'; then
            pactl set-card-profile "${bt_card}" a2dp-sink >/dev/null 2>&1 || true
            log "Switched ${bt_card} from ${active_profile} to a2dp-sink"
        fi
    done
}

if ! command -v pactl >/dev/null 2>&1; then
    exit 0
fi

# Wait briefly for PulseAudio-on-PipeWire to be reachable.
for _ in $(seq 1 20); do
    if pactl info >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

if ! pactl info >/dev/null 2>&1; then
    log "pactl info unavailable; skipping."
    exit 0
fi

# If a BT headset is stuck in HFP/HSP profile, push it back to A2DP first.
ensure_bluetooth_cards_a2dp

# Wait until at least one real sink/source is visible so we do not pin auto_null
# when PipeWire is still warming up.
for _ in $(seq 1 20); do
    if [ -n "$(list_sinks)" ] && [ -n "$(list_sources)" ]; then
        break
    fi
    sleep 0.5
done

sink_list="$(list_sinks)"
source_list="$(list_sources)"
if [ -z "${sink_list}" ] || [ -z "${source_list}" ]; then
    log "No real sink/source available yet; skipping."
    exit 0
fi

default_sink="$(pactl info | awk -F': ' '/^Default Sink:|^Destino por defecto:/{print $2; exit}')"
default_source="$(pactl info | awk -F': ' '/^Default Source:|^Fuente por defecto:/{print $2; exit}')"

sink_ok=1
source_ok=1

if [ -z "${default_sink}" ] || ! printf '%s\n' "${sink_list}" | grep -Fxq "${default_sink}"; then
    sink_ok=0
fi

if [ -z "${default_source}" ] || ! printf '%s\n' "${source_list}" | grep -Fxq "${default_source}"; then
    source_ok=0
fi

if [ "${BT_HFP_UNSTABLE}" -eq 1 ] && printf '%s\n' "${default_sink}" | grep -Eq '^bluez_output\.'; then
    sink_ok=0
    log "Bluetooth sink is in unstable HFP/HSP path; preferring non-Bluetooth sink"
fi

analog_source="$(printf '%s\n' "${source_list}" | grep -E '^alsa_input\..*analog-stereo$' | head -n1 || true)"
if [ -n "${analog_source}" ] && printf '%s\n' "${default_source}" | grep -Eq '^bluez_input\.'; then
    source_ok=0
    log "Default source is Bluetooth; preferring analog source (${analog_source}) for stability"
fi

if [ "${sink_ok}" -eq 1 ] && [ "${source_ok}" -eq 1 ]; then
    exit 0
fi

# If routing is broken, try to recover card profile first (best-effort).
card_name="$(pactl list cards short | awk '$2 ~ /alsa_card\\.pci-0000_00_1f\\.3/ {print $2; exit}')"
if [ -n "${card_name}" ]; then
    pactl set-card-profile "${card_name}" output:analog-stereo+input:analog-stereo >/dev/null 2>&1 || true
fi

pick_sink() {
    printf '%s\n' "${sink_list}" | grep -E '^alsa_output\..*analog-stereo$' | head -n1 || true
}

pick_source() {
    printf '%s\n' "${source_list}" | grep -E '^alsa_input\..*analog-stereo$' | head -n1 || true
}

if [ "${sink_ok}" -eq 0 ]; then
    candidate_sink="$(pick_sink)"
    if [ -z "${candidate_sink}" ]; then
        candidate_sink="$(printf '%s\n' "${sink_list}" | grep -E '^alsa_output\.' | head -n1 || true)"
    fi
    if [ -z "${candidate_sink}" ]; then
        candidate_sink="$(printf '%s\n' "${sink_list}" | grep -E '^bluez_output\.' | head -n1 || true)"
    fi
    if [ -z "${candidate_sink}" ]; then
        candidate_sink="$(printf '%s\n' "${sink_list}" | head -n1 || true)"
    fi
    if [ -n "${candidate_sink}" ]; then
        pactl set-default-sink "${candidate_sink}" >/dev/null 2>&1 || true
        log "Recovered default sink -> ${candidate_sink}"
    fi
fi

if [ "${source_ok}" -eq 0 ]; then
    candidate_source="$(pick_source)"
    if [ -z "${candidate_source}" ]; then
        candidate_source="$(printf '%s\n' "${source_list}" | grep -E '^alsa_input\.' | head -n1 || true)"
    fi
    if [ -z "${candidate_source}" ]; then
        candidate_source="$(printf '%s\n' "${source_list}" | grep -E '^bluez_input\.' | head -n1 || true)"
    fi
    if [ -z "${candidate_source}" ]; then
        candidate_source="$(printf '%s\n' "${source_list}" | head -n1 || true)"
    fi
    if [ -n "${candidate_source}" ]; then
        pactl set-default-source "${candidate_source}" >/dev/null 2>&1 || true
        log "Recovered default source -> ${candidate_source}"
    fi
fi

# Refresh desktop portal after route recovery (best-effort).
systemctl --user restart xdg-desktop-portal.service >/dev/null 2>&1 || true

exit 0
