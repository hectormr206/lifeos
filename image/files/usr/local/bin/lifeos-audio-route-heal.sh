#!/usr/bin/env bash
# LifeOS audio route self-heal.
# Repairs default sink/source when PipeWire/WirePlumber restarts or device IDs change.
set -euo pipefail

log() {
    echo "[lifeos-audio-heal] $*" >&2
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

default_sink="$(pactl info | awk -F': ' '/^Default Sink:|^Destino por defecto:/{print $2; exit}')"
default_source="$(pactl info | awk -F': ' '/^Default Source:|^Fuente por defecto:/{print $2; exit}')"

sink_list="$(pactl list short sinks | awk '{print $2}')"
source_list="$(pactl list short sources | awk '{print $2}')"

sink_ok=1
source_ok=1

if [ -z "${default_sink}" ] || ! printf '%s\n' "${sink_list}" | grep -Fxq "${default_sink}"; then
    sink_ok=0
fi

if [ -z "${default_source}" ] || ! printf '%s\n' "${source_list}" | grep -Fxq "${default_source}"; then
    source_ok=0
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
        candidate_source="$(printf '%s\n' "${source_list}" | grep -Ev '\\.monitor$' | head -n1 || true)"
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
