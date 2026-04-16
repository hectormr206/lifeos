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
# Uses `buildah from` + `buildah mount` to inspect the image rootfs without
# executing the entrypoint. This is bootc-safe — bootc images have a special
# entrypoint that `podman create` rejects. buildah's "working container" model
# never runs processes, so it always succeeds.
check_oci_image() {
    local image_ref="$1"
    local ctr=""
    local mountpoint=""
    local offenders=()
    local rc=0

    cleanup() {
        if [ -n "${mountpoint}" ] && [ -n "${ctr}" ]; then
            buildah umount "${ctr}" >/dev/null 2>&1 || true
        fi
        if [ -n "${ctr}" ]; then
            buildah rm "${ctr}" >/dev/null 2>&1 || true
        fi
    }
    trap cleanup RETURN

    # `buildah from --pull=never` creates a working container from a local or
    # referenced image without running its entrypoint. Capture stderr so real
    # errors are visible (unlike the previous podman-create path).
    if ! ctr=$(buildah from --pull=never "${image_ref}" 2>&1); then
        echo "ERROR: could not create working container from image: ${image_ref}" >&2
        echo "${ctr}" >&2
        ctr=""
        return 2
    fi

    if ! mountpoint=$(buildah mount "${ctr}" 2>&1); then
        echo "ERROR: could not mount working container filesystem: ${image_ref}" >&2
        echo "${mountpoint}" >&2
        mountpoint=""
        return 2
    fi

    for rel_path in "${FORBIDDEN_PATHS[@]}"; do
        if [ -e "${mountpoint}/${rel_path}" ]; then
            offenders+=("/${rel_path}")
        fi
    done

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
