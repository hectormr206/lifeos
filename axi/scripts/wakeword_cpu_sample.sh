#!/usr/bin/env bash
# Wake-word live-test CPU/RAM sampler — set-and-forget.
#
# Samples the axi-voice process CPU% and RSS every 2s to a CSV until Ctrl-C.
# This is the ONLY thing Héctor starts manually during a session; it runs in a
# spare terminal while he plays. The analyzer (wakeword_report.py --cpu-csv)
# reads the CSV afterward.
#
# Output columns: epoch,cpu_pct,rss_mb
# Robust to transient failures: if axi-voice restarts (new PID), it re-resolves
# the PID on the next tick instead of dying.
#
# Usage:
#   scripts/wakeword_cpu_sample.sh [OUTPUT_CSV] [INTERVAL_SECONDS]
# Defaults: OUTPUT_CSV=/tmp/axi-wakeword-cpu.csv  INTERVAL=2

set -u

OUT="${1:-/tmp/axi-wakeword-cpu.csv}"
INTERVAL="${2:-2}"

resolve_pid() {
  # Prefer systemd MainPID; fall back to pgrep. Echo empty on failure.
  local pid
  pid="$(systemctl --user show -p MainPID --value axi-voice 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && [ "$pid" != "0" ]; then
    echo "$pid"
    return 0
  fi
  pgrep -f 'axi-voice' 2>/dev/null | head -n1
}

# Write header (overwrite previous run).
echo "epoch,cpu_pct,rss_mb" > "$OUT"
echo "[wakeword_cpu_sample] writing to $OUT every ${INTERVAL}s — Ctrl-C to stop" >&2

trap 'echo "[wakeword_cpu_sample] stopped" >&2; exit 0' INT TERM

while true; do
  EPOCH="$(date +%s)"
  PID="$(resolve_pid)"

  if [ -z "${PID:-}" ]; then
    # process not running this tick — record a gap row with empty metrics
    echo "${EPOCH},," >> "$OUT"
    sleep "$INTERVAL"
    continue
  fi

  # ps gives instantaneous-ish CPU% (since process start) and RSS in KB.
  # %cpu can exceed 100 on multi-core; that's expected and the analyzer handles it.
  LINE="$(ps -p "$PID" -o %cpu=,rss= 2>/dev/null || true)"
  if [ -z "${LINE:-}" ]; then
    echo "${EPOCH},," >> "$OUT"
    sleep "$INTERVAL"
    continue
  fi

  CPU="$(echo "$LINE" | awk '{print $1}')"
  RSS_KB="$(echo "$LINE" | awk '{print $2}')"
  # convert KB -> MB (integer-ish)
  RSS_MB="$(awk "BEGIN{printf \"%.1f\", ${RSS_KB:-0}/1024}")"

  echo "${EPOCH},${CPU},${RSS_MB}" >> "$OUT"
  sleep "$INTERVAL"
done
