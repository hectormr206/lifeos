#!/bin/bash
# lifeos-detect-ecores.sh — Detect E-cores on Intel hybrid CPUs.
#
# Outputs a cpuset-compatible list (e.g., "16-31") of efficiency cores.
# On non-hybrid CPUs, outputs all CPUs (no restriction).
#
# Detection: E-cores have a lower cpuinfo_max_freq than P-cores.
# If all cores have the same max_freq, the CPU is not hybrid.

set -euo pipefail

declare -A freq_to_cpus
min_freq=999999999
max_freq=0

for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    [ -f "${cpu_dir}/cpuinfo_max_freq" ] || continue
    cpu_id=$(basename "$(dirname "$cpu_dir")" | sed 's/cpu//')
    freq=$(cat "${cpu_dir}/cpuinfo_max_freq")

    freq_to_cpus[$freq]="${freq_to_cpus[$freq]:-} $cpu_id"

    [ "$freq" -gt "$max_freq" ] && max_freq=$freq
    [ "$freq" -lt "$min_freq" ] && min_freq=$freq
done

# E-cores = CPUs at the LOWEST max frequency tier.
# On i9-13900HX: 3900MHz (E) vs 5200/5400MHz (P-cores at different boost levels).
# Only works on hybrid CPUs where min_freq != max_freq.
ecores=""
if [ "$min_freq" -lt "$max_freq" ]; then
    for cpu_id in ${freq_to_cpus[$min_freq]}; do
        ecores="${ecores:+$ecores,}${cpu_id}"
    done
fi

if [ -z "$ecores" ]; then
    # Not a hybrid CPU — output all CPUs (no restriction)
    nproc_val=$(nproc)
    echo "0-$((nproc_val - 1))"
else
    # Sort and compact the list
    echo "$ecores" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$/\n/'
fi
