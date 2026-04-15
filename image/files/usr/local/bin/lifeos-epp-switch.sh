#!/usr/bin/bash
# lifeos-epp-switch.sh — udev helper to flip energy_performance_preference.
#
# Called by /etc/udev/rules.d/85-lifeos-power-epp.rules when AC status
# changes. Kept as a separate script because udev's RUN= syntax treats `$`
# as a substitution prefix, which breaks any inline shell glob expansion
# over /sys paths.
#
# Argument: single value to write into each policy*/energy_performance_preference.
set -eu
VALUE="${1:-balance_power}"
case "${VALUE}" in
    performance|balance_performance|default|balance_power|power) ;;
    *)
        echo "lifeos-epp-switch: rejecting unknown EPP value '${VALUE}'" >&2
        exit 1
        ;;
esac
for f in /sys/devices/system/cpu/cpufreq/policy*/energy_performance_preference; do
    [ -f "$f" ] || continue
    printf '%s' "${VALUE}" > "$f" 2>/dev/null || true
done
