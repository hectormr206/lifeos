#!/usr/bin/env bash
# assert-no-dev-artifacts.sh
# Asserts that an OCI image or local filesystem tree does NOT contain
# any LifeOS dev-mode artifacts that must never ship in production images.
#
# Usage:
#   assert-no-dev-artifacts.sh <target>
#
# <target> is either:
#   - A local filesystem path (e.g., /tmp/rootfs or image/files)
#     Detection: argument does NOT start with a registry hostname pattern
#   - An OCI image reference (e.g., ghcr.io/hectormr206/lifeos:edge)
#     Detection: argument contains a '/' and a '.' before the first '/'
#
# Exit codes:
#   0 — No dev artifacts found.
#   1 — One or more forbidden dev artifacts found (offending paths printed).
#   2 — Usage error (no argument provided).
#
# Forbidden paths (the six paths that MUST NOT exist in a production image):
#   /etc/sudoers.d/lifeos-dev
#   /etc/sudoers.d/lifeos-dev-host
#   /etc/systemd/user/lifeosd.service.d/10-dev-mode.conf
#   /etc/systemd/user/lifeosd.service.d/10-dev-rust-log.conf
#   /etc/systemd/system/lifeos-sentinel.service.d/10-dev-mode-override.conf
#   /etc/systemd/system/lifeos-sentinel.service.d/10-dev-sentinel-path.conf

set -euo pipefail

# ── Forbidden paths ───────────────────────────────────────────────────────────
readonly FORBIDDEN_PATHS=(
    "etc/sudoers.d/lifeos-dev"
    "etc/sudoers.d/lifeos-dev-host"
    "etc/systemd/user/lifeosd.service.d/10-dev-mode.conf"
    "etc/systemd/user/lifeosd.service.d/10-dev-rust-log.conf"
    "etc/systemd/system/lifeos-sentinel.service.d/10-dev-mode-override.conf"
    "etc/systemd/system/lifeos-sentinel.service.d/10-dev-sentinel-path.conf"
)

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<'EOF'
Usage: assert-no-dev-artifacts.sh <target>

Assert that a LifeOS image or filesystem tree contains no dev-mode artifacts.

Arguments:
  <target>   OCI image reference (e.g., ghcr.io/hectormr206/lifeos:edge)
             or local filesystem path (e.g., image/files or /tmp/rootfs)

Exit codes:
  0  No forbidden dev artifacts found.
  1  One or more forbidden dev artifacts were found (paths listed on stdout).
  2  Usage error.

Forbidden paths:
  /etc/sudoers.d/lifeos-dev
  /etc/sudoers.d/lifeos-dev-host
  /etc/systemd/user/lifeosd.service.d/10-dev-mode.conf
  /etc/systemd/user/lifeosd.service.d/10-dev-rust-log.conf
  /etc/systemd/system/lifeos-sentinel.service.d/10-dev-mode-override.conf
  /etc/systemd/system/lifeos-sentinel.service.d/10-dev-sentinel-path.conf
EOF
}

if [ $# -eq 0 ]; then
    usage
    exit 2
fi

TARGET="$1"

# ── Determine mode ────────────────────────────────────────────────────────────
# Filesystem mode: target exists as a local path OR starts with '/' OR './'
# Image mode: contains a dot before the first slash (registry hostname pattern)
#             e.g., ghcr.io/... or containers-storage:... or localhost/...
is_oci_ref() {
    local t="$1"
    # OCI refs: contain '://' OR match hostname/... pattern (dot before first slash)
    # OR start with known prefixes
    case "${t}" in
        containers-storage:*|docker:*|oci:*|dir:*) return 0 ;;
        /*|./*|../*)                                return 1 ;;
        *)
            # Check if it looks like a registry ref: has a dot before first slash
            # e.g., ghcr.io/... or localhost/...
            local before_slash="${t%%/*}"
            if [[ "${before_slash}" == *"."* ]] || [[ "${before_slash}" == "localhost" ]]; then
                return 0
            fi
            # If the path exists on disk, treat as filesystem
            if [ -e "${t}" ]; then
                return 1
            fi
            # Default: treat as OCI ref
            return 0
            ;;
    esac
}

# ── Filesystem mode ───────────────────────────────────────────────────────────
check_filesystem() {
    local root="$1"
    local offenders=()

    for rel_path in "${FORBIDDEN_PATHS[@]}"; do
        if [ -e "${root}/${rel_path}" ]; then
            offenders+=("/${rel_path}")
        fi
    done

    if [ "${#offenders[@]}" -gt 0 ]; then
        echo "FAILED: Dev artifacts found in ${root}:"
        for p in "${offenders[@]}"; do
            echo "  ${p}"
        done
        return 1
    fi

    echo "No dev artifacts found."
    return 0
}

# ── OCI image mode ────────────────────────────────────────────────────────────
# Inspects an image by running `podman run --entrypoint /bin/bash` inside it
# and probing the forbidden paths with `test -e`. This avoids both the
# bootc-incompatible `podman create ... true` path AND the buildah/podman
# storage mismatch that plagued a `buildah from` approach on rootless runners.
check_oci_image() {
    local image_ref="$1"
    local offenders=()
    local rc=0

    # Strip the `containers-storage:` transport prefix if present — podman
    # run does its own storage lookup and chokes on the explicit prefix when
    # the name is unqualified (it gets re-resolved as docker.io/library/<name>).
    local podman_ref="${image_ref#containers-storage:}"

    # Build a bash probe that prints `found:<path>` for each forbidden path
    # that exists inside the image. Unknown-size arrays are safe here because
    # FORBIDDEN_PATHS is a fixed readonly list defined above.
    local probe="set -e; "
    for rel_path in "${FORBIDDEN_PATHS[@]}"; do
        probe+="test -e '/${rel_path}' && echo 'found:${rel_path}'; "
    done
    probe+="true"

    local probe_out
    if ! probe_out=$(podman run --rm --entrypoint /bin/bash "${podman_ref}" -lc "${probe}" 2>&1); then
        echo "ERROR: could not run probe inside image: ${image_ref}" >&2
        echo "${probe_out}" >&2
        return 2
    fi

    while IFS= read -r line; do
        case "${line}" in
            found:*) offenders+=("/${line#found:}") ;;
        esac
    done <<< "${probe_out}"

    if [ "${#offenders[@]}" -gt 0 ]; then
        echo "FAILED: Dev artifacts found in image ${image_ref}:"
        for p in "${offenders[@]}"; do
            echo "  ${p}"
        done
        rc=1
    else
        echo "No dev artifacts found."
        rc=0
    fi

    return "${rc}"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
if is_oci_ref "${TARGET}"; then
    check_oci_image "${TARGET}"
else
    check_filesystem "${TARGET}"
fi
