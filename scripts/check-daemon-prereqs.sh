#!/usr/bin/env bash
# Validate local prerequisites required to build and validate
# `lifeosd --all-features` on a self-hosted LifeOS developer machine.

set -euo pipefail

# Try to load Rust toolchain from rustup if PATH is incomplete.
for env_file in "$HOME/.cargo/env" "/var/home/${USER:-lifeos}/.cargo/env"; do
    if [ -f "$env_file" ]; then
        # shellcheck disable=SC1090
        . "$env_file"
        break
    fi
done
export PATH="$HOME/.cargo/bin:/var/home/${USER:-lifeos}/.cargo/bin:$PATH"

missing_cmd=()
for cmd in cargo rustc pkg-config rustfmt; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing_cmd+=("$cmd")
    fi
done

if ! cargo clippy --version >/dev/null 2>&1; then
    missing_cmd+=("clippy")
fi

if [ "${#missing_cmd[@]}" -gt 0 ]; then
    echo "Missing required commands: ${missing_cmd[*]}"
    echo "Latest LifeOS developer images ship the Rust + GTK build baseline on the host."
    echo "Install the Rust toolchain + pkg-config before building daemon."
    exit 1
fi

missing_pkg=()
for pc in dbus-1 glib-2.0 gtk4 libadwaita-1; do
    if ! pkg-config --exists "$pc"; then
        missing_pkg+=("$pc")
    fi
done

if [ "${#missing_pkg[@]}" -gt 0 ]; then
    echo "Missing pkg-config libraries: ${missing_pkg[*]}"
    if [ -f /run/ostree-booted ]; then
        echo "Detected immutable ostree/bootc host (root is read-only)."
        echo "If your image is outdated, update to latest LifeOS first and reboot:"
        echo "  life update"
        echo "  sudo reboot"
        echo "Install build deps in a toolbox container:"
        echo "  toolbox create lifeos-dev"
        echo "  toolbox enter lifeos-dev"
        echo "  sudo dnf install pkgconf-pkg-config dbus-devel glib2-devel gtk4-devel libadwaita-devel"
        echo "  cd /var/home/${USER:-lifeos}/personalProjects/gama/lifeos"
        echo "  bash scripts/check-daemon-prereqs.sh"
        echo "  bash scripts/phase3-hardening-checks.sh"
        exit 1
    fi
    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            fedora|rhel|centos)
                echo "Install with:"
                echo "  sudo dnf install pkgconf-pkg-config dbus-devel glib2-devel gtk4-devel libadwaita-devel"
                ;;
            ubuntu|debian)
                echo "Install with:"
                echo "  sudo apt-get install pkg-config libdbus-1-dev libglib2.0-dev libgtk-4-dev libadwaita-1-dev"
                ;;
            *)
                echo "Install the development packages for dbus, glib2, gtk4, and libadwaita."
                ;;
        esac
    fi
    exit 1
fi

if ! command -v cargo-audit >/dev/null 2>&1; then
    echo "NOTE: cargo-audit not found."
    echo "Latest LifeOS developer images include it so \`make ci\` works on-host."
fi

echo "All daemon build prerequisites are installed."
echo "Ready for: cd daemon && cargo build --all-features"
