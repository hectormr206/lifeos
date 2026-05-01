#!/usr/bin/env bash
#
# vps-registry-gc.sh — Reclaim disk in the LifeOS dev registry.
#
# Two passes:
#   1. **Tag prune**: delete any manifest whose tag matches `dev`, `branch-*`,
#      or any sha-only digest, and whose blob is older than $TTL_HOURS.
#      `:stable`, `:edge`, `:latest`, and `vN.N.N` tags are NEVER pruned —
#      they're release-relevant.
#   2. **Garbage collect**: walk blob storage, delete blobs with no manifest
#      reference. This is the step that actually frees disk.
#
# Requires the registry to have been started with
# REGISTRY_STORAGE_DELETE_ENABLED=true (see vps-registry-setup.sh). Without
# that, the tag-prune DELETE calls return 405 and pass 2 has nothing to do.
#
# Schedule via vps-registry-gc.timer at 04:00 local. Manual run is also safe;
# the registry stays up the whole time (GC takes a read-only snapshot lock by
# default, but with --delete-untagged=true it's fine to run alongside reads).
#
# Run on the VPS as the operator user.

set -euo pipefail

CONTAINER_NAME="lifeos-registry"
REGISTRY_URL="http://10.66.66.1:5001"
TTL_HOURS="${TTL_HOURS:-72}"
DRY_RUN="${DRY_RUN:-0}"

# Tags we NEVER touch — release-relevant.
PROTECTED_TAG_REGEX='^(stable|edge|latest|v[0-9]+\.[0-9]+\.[0-9]+)$'

log() { printf "[vps-registry-gc] %s\n" "$*"; }

cutoff_epoch=$(date -d "$TTL_HOURS hours ago" +%s)
log "TTL=$TTL_HOURS h — cutoff epoch=$cutoff_epoch ($(date -d @$cutoff_epoch))"
[[ "$DRY_RUN" == "1" ]] && log "DRY_RUN mode — no DELETEs will fire."

before_bytes=$(sudo du -sb /home/hectormr/registry-data 2>/dev/null | cut -f1)
log "Storage before: $(numfmt --to=iec --suffix=B "$before_bytes")"

# ---------------------------------------------------------------------------
# Pass 1: tag prune
# ---------------------------------------------------------------------------
deleted_tags=0
for repo in $(curl -s "$REGISTRY_URL/v2/_catalog" | jq -r '.repositories[]?'); do
    log "Repo: $repo"
    for tag in $(curl -s "$REGISTRY_URL/v2/$repo/tags/list" | jq -r '.tags[]? // empty'); do
        if [[ "$tag" =~ $PROTECTED_TAG_REGEX ]]; then
            continue
        fi

        # Fetch the manifest digest. Accept BOTH docker v2 and OCI manifest
        # formats — the registry stores whatever the pusher produced. `grep ||
        # true` prevents pipefail from killing us when the header is absent
        # (404 manifest, transient network, wrong content-type negotiation).
        digest=$(curl -sI \
            -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            -H "Accept: application/vnd.oci.image.manifest.v1+json" \
            -H "Accept: application/vnd.oci.image.index.v1+json" \
            -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
            "$REGISTRY_URL/v2/$repo/manifests/$tag" \
            | { grep -i '^docker-content-digest:' || true; } | tr -d '\r' | awk '{print $2}')

        if [[ -z "$digest" ]]; then
            log "  [skip] $repo:$tag — no manifest digest (transient?)"
            continue
        fi

        # Pull the config blob to read .created.
        config_digest=$(curl -s \
            -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            "$REGISTRY_URL/v2/$repo/manifests/$digest" \
            | jq -r '.config.digest // empty')

        if [[ -z "$config_digest" ]]; then
            log "  [skip] $repo:$tag — no config digest"
            continue
        fi

        created=$(curl -s "$REGISTRY_URL/v2/$repo/blobs/$config_digest" \
            | jq -r '.created // empty')

        if [[ -z "$created" ]]; then
            log "  [skip] $repo:$tag — no .created in config"
            continue
        fi

        created_epoch=$(date -d "$created" +%s 2>/dev/null || echo 0)
        if (( created_epoch == 0 )); then
            log "  [skip] $repo:$tag — unparseable created='$created'"
            continue
        fi

        if (( created_epoch >= cutoff_epoch )); then
            log "  [keep] $repo:$tag — created $created (within TTL)"
            continue
        fi

        log "  [prune] $repo:$tag — created $created (older than ${TTL_HOURS}h)"
        if [[ "$DRY_RUN" != "1" ]]; then
            curl -s -X DELETE "$REGISTRY_URL/v2/$repo/manifests/$digest" >/dev/null
            (( deleted_tags+=1 )) || true
        fi
    done
done
log "Tags pruned: $deleted_tags"

# ---------------------------------------------------------------------------
# Pass 2: registry garbage-collect
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN — skipping garbage-collect."
else
    log "Running registry garbage-collect..."
    sudo docker exec "$CONTAINER_NAME" \
        registry garbage-collect /etc/docker/registry/config.yml \
        --delete-untagged=true 2>&1 | tail -10
fi

after_bytes=$(sudo du -sb /home/hectormr/registry-data 2>/dev/null | cut -f1)
freed_bytes=$(( before_bytes - after_bytes ))
log "Storage after: $(numfmt --to=iec --suffix=B "$after_bytes")"
log "Reclaimed: $(numfmt --to=iec --suffix=B "$freed_bytes")"
