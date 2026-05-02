#!/usr/bin/env bash
#
# distrobox-dev-setup.sh — Provision the LifeOS developer distrobox.
#
# Phase 0 of the architecture pivot. Creates a Fedora 44 distrobox named
# `lifeos-dev` with everything you need to:
#   - cargo build the daemon + cli WITHOUT touching the host bootc rootfs
#   - podman build any of the lifeos-* containers
#   - use rust-analyzer in your editor without polluting the host
#
# The distrobox is the inner-loop substrate. Everything that's NOT a
# container build (debugging, profiling, exploring with cargo) lives here.
# The bootc host stays clean.
#
# Idempotent — safe to re-run. If the distrobox exists, this just refreshes
# the package list inside it.
#
# Usage:
#   bash scripts/distrobox-dev-setup.sh
#
# Or one-shot from elsewhere:
#   curl -fsSL https://raw.githubusercontent.com/hectormr206/lifeos/main/scripts/distrobox-dev-setup.sh | bash

set -euo pipefail

DISTROBOX_NAME="lifeos-dev"
BASE_IMAGE="quay.io/fedora/fedora:44"

log() { printf "[distrobox-dev-setup] %s\n" "$*"; }

# 1. Detect distrobox availability. On LifeOS bootc 0.8.x distrobox ships in
#    the image. On other distros the user installs it themselves.
if ! command -v distrobox >/dev/null 2>&1; then
    log "ERROR: distrobox not found in PATH."
    log "  - On LifeOS: distrobox should be pre-installed. Check 'rpm -q distrobox'."
    log "  - On other distros: see https://distrobox.it/#installation"
    exit 1
fi

# 2. Detect NVIDIA presence to know whether to add --nvidia. Distrobox supports
#    GPU passthrough natively but only when the host has the NVIDIA stack
#    installed. On AMD/Intel we skip the flag.
nvidia_args=()
if command -v nvidia-smi >/dev/null 2>&1; then
    log "NVIDIA GPU detected — distrobox will have --nvidia GPU passthrough."
    nvidia_args=(--nvidia)
else
    log "No NVIDIA GPU on host — distrobox will run CPU-only (fine for daemon dev)."
fi

# 3. Create or refresh the distrobox.
if distrobox list 2>/dev/null | grep -q "^$DISTROBOX_NAME\\b"; then
    log "Distrobox '$DISTROBOX_NAME' already exists — refreshing packages instead of recreating."
else
    log "Creating distrobox '$DISTROBOX_NAME' from $BASE_IMAGE..."
    distrobox create \
        --name "$DISTROBOX_NAME" \
        --image "$BASE_IMAGE" \
        --yes \
        "${nvidia_args[@]}"
fi

# 4. Install dev deps inside the distrobox. dnf is idempotent — if a package
#    is already installed it just exits 0. So we can re-run this on every
#    setup invocation without harm.
log "Installing dev dependencies inside the distrobox..."
distrobox enter "$DISTROBOX_NAME" -- bash -c '
    set -euo pipefail

    # Use sudo INSIDE the distrobox (it inherits sudo with no password by
    # default for the distrobox user — that is the whole point of distrobox).
    sudo dnf install -y \
        rust cargo rustfmt clippy rust-analyzer \
        gcc gcc-c++ make cmake \
        pkgconf-pkg-config \
        openssl-devel sqlite-devel dbus-devel glib2-devel \
        wayland-devel libxkbcommon-devel \
        gtk4-devel libadwaita-devel \
        git gh \
        bat ripgrep fd-find eza fzf zoxide \
        podman buildah skopeo \
        ca-certificates curl jq \
        && \
    sudo dnf clean all

    # Sanity check — Rust toolchain should be ready.
    rustc --version
    cargo --version
'

# 5. Print next-steps for the user.
log ""
log "Done. Quick start:"
log "  distrobox enter $DISTROBOX_NAME"
log "  cd ~/dev/gama/lifeos/lifeos"
log "  cargo build --manifest-path daemon/Cargo.toml"
log ""
log "To rebuild a container from inside the distrobox:"
log "  podman build -t 10.66.66.1:5001/lifeos-tts:dev \\"
log "    -f containers/lifeos-tts/Containerfile containers/lifeos-tts/"
log ""
log "See docs/contributor/quadlet-dev-workflow.md for the full edit→test→promote loop."
