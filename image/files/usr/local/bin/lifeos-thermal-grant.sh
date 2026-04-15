#!/usr/bin/bash
# lifeos-thermal-grant.sh — udev helper that chowns/chmods thermal sysfs
# nodes so the `lifeos` group can write them without sudo.
#
# Called by /etc/udev/rules.d/90-lifeos-thermal.rules on every `cpu` subsystem
# add/change event. Kept out of the rule itself because udev's RUN= parser
# rejects shell variable substitution ($f), which breaks any inline glob.
set -eu
for f in /sys/devices/system/cpu/intel_pstate/max_perf_pct \
         /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq; do
    [ -f "$f" ] || continue
    chgrp lifeos "$f" 2>/dev/null || true
    chmod 0660  "$f" 2>/dev/null || true
done
