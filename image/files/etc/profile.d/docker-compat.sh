#!/bin/sh
# Prefer rootless Podman socket for Docker-compatible clients.

if command -v podman >/dev/null 2>&1; then
    uid_value="$(id -u 2>/dev/null || true)"
    if [ -n "${uid_value}" ] && [ -S "/run/user/${uid_value}/podman/podman.sock" ]; then
        export DOCKER_HOST="unix:///run/user/${uid_value}/podman/podman.sock"
    fi
    unset uid_value
fi
