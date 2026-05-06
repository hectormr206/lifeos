#!/bin/bash
# postdeploy-overlay-cleanup.sh — remove the manual hotfix overlays + env-file
# pin that were applied during the May 2026 lifeos-nvidia-drivers Vulkan-headless
# debugging sprint. Run AFTER deploying the bootc image that ships:
#   - lifeos-lifeosd.container with AddDevice=nvidia.com/gpu=all + CDI poll
#     ExecStartPre (PR fix/daemon-gpu-detect-and-cpu-fallback)
#   - lifeos-llama-server.container with bash-wrapped Exec= +
#     ${LIFEOS_AI_DEVICE_FLAGS:+...}/${LIFEOS_AI_GPU_TUNING:+...}
#     (same PR)
#   - lifeos-llama-server CUDA image (PR feat/lifeos-llama-server-cuda)
#
# Until those PRs land + bootc image is upgraded on the host, this script is
# a no-op AT BEST and harmful at worst (could remove the only working config).
# DO NOT run unless `bootc status` shows the booted image is post-PR.
#
# Idempotent: skips files that don't exist; warnings are non-fatal.

set -uo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root (got uid=$EUID)"
    exit 1
fi

echo "=== postdeploy overlay cleanup ==="
echo

# 1. Remove /etc/containers/systemd/ overlays — the bootc image ships the
#    canonical Quadlets at /usr/share/containers/systemd/, which Quadlet
#    prefers when /etc/ has no override. Removing /etc lets the new
#    /usr/share definitions win.
for overlay in /etc/containers/systemd/lifeos-lifeosd.container \
               /etc/containers/systemd/lifeos-llama-server.container; do
    if [[ -f "$overlay" ]]; then
        echo "removing overlay: $overlay"
        rm -f "$overlay"
    else
        echo "skip: $overlay (not present)"
    fi
done

# 2. Drop the chattr +i pin on the runtime profile env file so the daemon
#    can manage it again. Post-PR the daemon detects the GPU via nvidia-smi
#    and writes a CUDA-enabled GPU profile (LIFEOS_AI_GPU_LAYERS=99,
#    LIFEOS_AI_DEVICE_FLAGS empty, LIFEOS_AI_GPU_TUNING populated). On a
#    host without GPU it writes the CPU profile (--device none) instead.
ENV_FILE=/var/lib/lifeos/llama-server-runtime-profile.env
if [[ -f "$ENV_FILE" ]]; then
    if lsattr "$ENV_FILE" 2>/dev/null | grep -q -- "----i"; then
        echo "removing immutable bit on $ENV_FILE"
        chattr -i "$ENV_FILE" || echo "WARN: chattr -i failed — file ignored"
    else
        echo "skip: $ENV_FILE not immutable"
    fi
else
    echo "skip: $ENV_FILE not present"
fi

# 3. Reload systemd so the new Quadlet definitions take effect, then
#    restart lifeos-lifeosd (which writes the runtime profile env file)
#    followed by lifeos-llama-server (which reads it).
echo
echo "=== reload + restart ==="
systemctl daemon-reload
systemctl reset-failed lifeos-lifeosd.service lifeos-llama-server.service 2>/dev/null || true
systemctl restart lifeos-lifeosd.service
echo "waiting 30 s for daemon to detect GPU + rewrite env file"
sleep 30
systemctl restart lifeos-llama-server.service
echo "waiting 60 s for model load"
sleep 60

echo
echo "=== final state ==="
systemctl is-active lifeos-lifeosd.service lifeos-llama-server.service || true
echo
echo "--- runtime-profile.env ---"
cat /var/lib/lifeos/llama-server-runtime-profile.env
echo
echo "--- /health ---"
curl -sf --max-time 5 http://127.0.0.1:8082/health || echo "(no response)"
