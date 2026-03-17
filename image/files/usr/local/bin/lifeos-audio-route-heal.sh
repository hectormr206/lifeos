#!/usr/bin/env bash
# LifeOS audio route self-heal.
# Repairs default sink/source when PipeWire/WirePlumber restarts or device IDs change.
set -euo pipefail
PREFER_EXTERNAL_SOURCE="${LIFEOS_AUDIO_PREFER_EXTERNAL_SOURCE:-0}"
PREFER_EXTERNAL_SINK="${LIFEOS_AUDIO_PREFER_EXTERNAL_SINK:-0}"
FORCE_BT_HEADSET_PROFILE="${LIFEOS_AUDIO_FORCE_BT_HEADSET_PROFILE:-0}"
REQUIRE_PAIRED_IO="${LIFEOS_AUDIO_REQUIRE_PAIRED_IO:-0}"

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

ensure_bluetooth_headset_source() {
    local bt_cards bt_card card_block active_profile switched
    switched=0
    bt_cards="$(pactl list cards short | awk '$2 ~ /^bluez_card\./ {print $2}')"
    if [ -z "${bt_cards}" ]; then
        return 1
    fi

    for bt_card in ${bt_cards}; do
        card_block="$(extract_card_block "${bt_card}")"
        if ! printf '%s\n' "${card_block}" | grep -q 'headset-head-unit'; then
            continue
        fi

        active_profile="$(printf '%s\n' "${card_block}" | awk -F': ' '/Active Profile:|Perfil Activo:/{print $2; exit}')"
        if printf '%s\n' "${active_profile}" | grep -Eq '^headset-head-unit(-cvsd)?$'; then
            continue
        fi

        if pactl set-card-profile "${bt_card}" headset-head-unit >/dev/null 2>&1; then
            log "Enabled headset profile on ${bt_card} to expose Bluetooth microphone"
            switched=1
            break
        fi

        if pactl set-card-profile "${bt_card}" headset-head-unit-cvsd >/dev/null 2>&1; then
            log "Enabled CVSD headset profile on ${bt_card} to expose Bluetooth microphone"
            switched=1
            break
        fi
    done

    [ "${switched}" -eq 1 ]
}

pick_sink() {
    local candidate=""
    candidate="$(printf '%s\n' "${sink_list}" | grep -E '^bluez_output\.' | head -n1 || true)"
    if [ -z "${candidate}" ]; then
        candidate="$(printf '%s\n' "${sink_list}" | grep -E '^alsa_output\..*analog-stereo$' | head -n1 || true)"
    fi
    if [ -z "${candidate}" ]; then
        candidate="$(printf '%s\n' "${sink_list}" | grep -E '^alsa_output\.' | head -n1 || true)"
    fi
    if [ -z "${candidate}" ]; then
        candidate="$(printf '%s\n' "${sink_list}" | head -n1 || true)"
    fi
    printf '%s' "${candidate}"
}

pick_source() {
    local candidate=""
    candidate="$(printf '%s\n' "${source_list}" | grep -E '^bluez_input\.' | head -n1 || true)"
    if [ -z "${candidate}" ]; then
        candidate="$(printf '%s\n' "${source_list}" | grep -E '^alsa_input\.usb-' | head -n1 || true)"
    fi
    if [ -z "${candidate}" ]; then
        candidate="$(printf '%s\n' "${source_list}" | grep -E '^alsa_input\..*analog-stereo$' | head -n1 || true)"
    fi
    if [ -z "${candidate}" ]; then
        candidate="$(printf '%s\n' "${source_list}" | grep -E '^alsa_input\.' | head -n1 || true)"
    fi
    if [ -z "${candidate}" ]; then
        candidate="$(printf '%s\n' "${source_list}" | head -n1 || true)"
    fi
    printf '%s' "${candidate}"
}

pick_paired_io() {
    local src addr sink usb_key
    PREFERRED_PAIR_SINK=""
    PREFERRED_PAIR_SOURCE=""

    # 1) Prefer Bluetooth pair (same MAC in bluez_input/bluez_output)
    while IFS= read -r src; do
        [ -z "${src}" ] && continue
        addr="$(printf '%s' "${src}" | sed -E 's/^bluez_input\.([^.]+).*/\1/')"
        sink="$(printf '%s\n' "${sink_list}" | grep -E "^bluez_output\.${addr}(\.|$)" | head -n1 || true)"
        if [ -n "${sink}" ]; then
            PREFERRED_PAIR_SOURCE="${src}"
            PREFERRED_PAIR_SINK="${sink}"
            return 0
        fi
    done <<EOF
$(printf '%s\n' "${source_list}" | grep -E '^bluez_input\.' || true)
EOF

    # 2) Prefer USB pair (same alsa usb key)
    while IFS= read -r src; do
        [ -z "${src}" ] && continue
        usb_key="$(printf '%s' "${src}" | sed -nE 's/^alsa_input\.(usb-[^.]+)\..*/\1/p')"
        [ -z "${usb_key}" ] && continue
        sink="$(printf '%s\n' "${sink_list}" | grep -E "^alsa_output\.${usb_key}\." | head -n1 || true)"
        if [ -n "${sink}" ]; then
            PREFERRED_PAIR_SOURCE="${src}"
            PREFERRED_PAIR_SINK="${sink}"
            return 0
        fi
    done <<EOF
$(printf '%s\n' "${source_list}" | grep -E '^alsa_input\.usb-' || true)
EOF

    # 3) Prefer internal analog pair
    src="$(printf '%s\n' "${source_list}" | grep -E '^alsa_input\..*analog-stereo$' | head -n1 || true)"
    sink="$(printf '%s\n' "${sink_list}" | grep -E '^alsa_output\..*analog-stereo$' | head -n1 || true)"
    if [ -n "${src}" ] && [ -n "${sink}" ]; then
        PREFERRED_PAIR_SOURCE="${src}"
        PREFERRED_PAIR_SINK="${sink}"
        return 0
    fi

    return 1
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

if [ "${FORCE_BT_HEADSET_PROFILE}" = "1" ] \
    && ! printf '%s\n' "${source_list}" | grep -Eq '^bluez_input\.'; then
    if ensure_bluetooth_headset_source; then
        sleep 0.5
        sink_list="$(list_sinks)"
        source_list="$(list_sources)"
    fi
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

preferred_sink="$(pick_sink)"
preferred_source="$(pick_source)"
PREFERRED_PAIR_SINK=""
PREFERRED_PAIR_SOURCE=""
pick_paired_io || true

if [ "${sink_ok}" -eq 0 ] && [ "${source_ok}" -eq 0 ] \
    && [ "${REQUIRE_PAIRED_IO}" = "1" ] \
    && [ -n "${PREFERRED_PAIR_SINK}" ] \
    && [ -n "${PREFERRED_PAIR_SOURCE}" ] \
    && { [ "${default_sink}" != "${PREFERRED_PAIR_SINK}" ] || [ "${default_source}" != "${PREFERRED_PAIR_SOURCE}" ]; }; then
    sink_ok=0
    source_ok=0
    log "Preferring paired I/O (${PREFERRED_PAIR_SINK} / ${PREFERRED_PAIR_SOURCE})"
fi

if [ "${sink_ok}" -eq 0 ] \
    && [ "${PREFER_EXTERNAL_SINK}" = "1" ] \
    && [ -n "${preferred_sink}" ] \
    && [ "${preferred_sink}" != "${default_sink}" ] \
    && printf '%s\n' "${preferred_sink}" | grep -Eq '^(bluez_output\.|alsa_output\.usb-)'; then
    sink_ok=0
    log "Preferring external sink (${preferred_sink})"
fi

if [ "${source_ok}" -eq 0 ] \
    && [ "${PREFER_EXTERNAL_SOURCE}" = "1" ] \
    && [ -n "${preferred_source}" ] \
    && [ "${preferred_source}" != "${default_source}" ] \
    && { printf '%s\n' "${preferred_source}" | grep -Eq '^bluez_input\.' \
      || printf '%s\n' "${preferred_source}" | grep -Eq '^alsa_input\.usb-'; }; then
    source_ok=0
    log "Preferring external source (${preferred_source})"
fi

if [ "${sink_ok}" -eq 1 ] && [ "${source_ok}" -eq 1 ]; then
    exit 0
fi

if [ "${sink_ok}" -eq 0 ]; then
    candidate_sink="${PREFERRED_PAIR_SINK:-}"
    if [ -z "${candidate_sink}" ]; then
        candidate_sink="$(pick_sink)"
    fi
    if [ -n "${candidate_sink}" ]; then
        pactl set-default-sink "${candidate_sink}" >/dev/null 2>&1 || true
        log "Recovered default sink -> ${candidate_sink}"
    fi
fi

if [ "${source_ok}" -eq 0 ]; then
    candidate_source="${PREFERRED_PAIR_SOURCE:-}"
    if [ -z "${candidate_source}" ]; then
        candidate_source="$(pick_source)"
    fi
    if [ -n "${candidate_source}" ]; then
        pactl set-default-source "${candidate_source}" >/dev/null 2>&1 || true
        log "Recovered default source -> ${candidate_source}"
    fi
fi

# Refresh desktop portal after route recovery (best-effort).
systemctl --user restart xdg-desktop-portal.service >/dev/null 2>&1 || true

exit 0
