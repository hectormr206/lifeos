#!/usr/bin/env bash
#
# vps-registry-setup.sh — Provisions / hardens the LifeOS dev registry on the
# VPS for the dual-registry workflow defined in
# docs/strategy/prd-architecture-pivot-lean-bootc-quadlet.md §5c.
#
# What it ensures (idempotent):
#   1. The `lifeos-registry` Docker container is running with
#      REGISTRY_STORAGE_DELETE_ENABLED=true, which makes the v2 registry honor
#      DELETE manifest API calls (required by garbage-collect to actually
#      reclaim storage).
#   2. /home/hectormr/registry-data is the bind mount and survives recreates.
#   3. Listening on 10.66.66.1:5001 (WireGuard side only — never public).
#   4. Restart policy: always.
#
# Run on the VPS as the operator user (sudo passwordless required for docker).
# Run anytime — recreating the container is a ~10s blip. Schedule deploys
# around it if a build is in-flight.
#
# Companion scripts:
#   scripts/vps-registry-gc.sh       — manual GC + dev tag prune (also
#                                       installed as a daily systemd timer)
#   scripts/vps-registry-gc.timer    — runs the prune at 04:00 local
#
# Usage:
#   ssh hectormr@10.66.66.1 "bash -s" < scripts/vps-registry-setup.sh

set -euo pipefail

CONTAINER_NAME="lifeos-registry"
REGISTRY_IMAGE="registry:2"
DATA_DIR="/home/hectormr/registry-data"
LISTEN_ADDR="10.66.66.1:5001"

log() { printf "[vps-registry-setup] %s\n" "$*"; }

# 1. Ensure data dir exists with the right ownership. Registry image runs as
#    UID 1000 by default (matches our hectormr user — happy accident). Keep
#    perms drwxr-x--- so the world can't enumerate blobs.
sudo mkdir -p "$DATA_DIR"
sudo chown -R 1000:1000 "$DATA_DIR"
sudo chmod 750 "$DATA_DIR"

# 2. Inspect current state. If the container exists and already has DELETE
#    enabled, exit early — nothing to do.
existing_env=""
if sudo docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    existing_env=$(sudo docker inspect "$CONTAINER_NAME" \
        --format '{{range .Config.Env}}{{println .}}{{end}}')
    if grep -q "^REGISTRY_STORAGE_DELETE_ENABLED=true$" <<< "$existing_env"; then
        log "Registry already has DELETE enabled — nothing to do."
        sudo docker ps --filter "name=$CONTAINER_NAME" --format "  {{.Names}} ({{.Status}})"
        exit 0
    fi
    log "Registry exists but DELETE is NOT enabled — recreating."
    sudo docker stop "$CONTAINER_NAME" >/dev/null
    sudo docker rm "$CONTAINER_NAME" >/dev/null
fi

# 3. Create the registry with DELETE enabled. The other settings reproduce the
#    pre-existing container so behavior of running services (deploy script,
#    skopeo copy from GHCR) is preserved.
log "Starting $CONTAINER_NAME with DELETE enabled..."
sudo docker run -d \
    --name "$CONTAINER_NAME" \
    --restart=always \
    --network=bridge \
    -p "$LISTEN_ADDR:5000" \
    -v "$DATA_DIR:/var/lib/registry" \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    "$REGISTRY_IMAGE" >/dev/null

# 4. Health check — give it 5s to come up, then probe /v2/.
sleep 5
if ! curl -sf "http://$LISTEN_ADDR/v2/" >/dev/null; then
    log "ERROR: registry not responding on $LISTEN_ADDR/v2/ after start."
    sudo docker logs --tail=30 "$CONTAINER_NAME"
    exit 1
fi

log "Registry is up. Catalog:"
curl -s "http://$LISTEN_ADDR/v2/_catalog" | jq -r '.repositories[]?' | sed 's/^/  /'

log "Done. Remember to run scripts/vps-registry-gc.sh once to reclaim space"
log "from the historical accumulation now that DELETE is enabled."
