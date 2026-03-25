#!/usr/bin/env bash
set -euo pipefail

profile="${1:-}"

if [[ -z "$profile" ]]; then
    echo "Usage: $0 <daemon|runtime|podman|e2e>"
    exit 2
fi

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "sudo is required to install packages"
        exit 1
    fi
    SUDO="sudo"
fi

pm_detected=""
if command -v apt-get >/dev/null 2>&1; then
    pm_detected="apt"
elif command -v dnf >/dev/null 2>&1; then
    pm_detected="dnf"
fi

install_pkgs() {
    local apt_pkgs="$1"
    local dnf_pkgs="$2"

    if [[ "$pm_detected" == "apt" ]]; then
        $SUDO apt-get update
        # shellcheck disable=SC2086
        $SUDO apt-get install -y $apt_pkgs
        return
    fi

    if [[ "$pm_detected" == "dnf" ]]; then
        # shellcheck disable=SC2086
        $SUDO dnf install -y $dnf_pkgs
        return
    fi

    echo "Unsupported Linux package manager. Neither apt-get nor dnf found."
    exit 1
}

case "$profile" in
    daemon)
        # Always ensure wayland/xkbcommon are present (cosmic-protocols build.rs needs them)
        if ! pkg-config --exists xkbcommon 2>/dev/null || ! pkg-config --exists wayland-client 2>/dev/null; then
            echo "Installing wayland/xkbcommon dev libraries..."
            install_pkgs \
                "libwayland-dev libxkbcommon-dev" \
                "wayland-devel libxkbcommon-devel"
        fi

        # Check remaining core prerequisites (GTK4, dbus, pkg-config)
        if bash scripts/check-daemon-prereqs.sh >/dev/null 2>&1; then
            echo "daemon prerequisites already installed"
            exit 0
        fi

        install_pkgs \
            "pkg-config libdbus-1-dev libglib2.0-dev libgtk-4-dev libadwaita-1-dev libwayland-dev libxkbcommon-dev" \
            "pkgconf-pkg-config dbus-devel glib2-devel gtk4-devel libadwaita-devel wayland-devel libxkbcommon-devel"
        bash scripts/check-daemon-prereqs.sh
        ;;
    runtime)
        missing=0
        command -v curl >/dev/null 2>&1 || missing=1
        command -v dbus-daemon >/dev/null 2>&1 || missing=1
        if [[ "$missing" -eq 0 ]]; then
            echo "runtime prerequisites already installed"
            exit 0
        fi
        install_pkgs \
            "curl dbus libdbus-1-3" \
            "curl dbus dbus-libs"
        ;;
    podman)
        if command -v podman >/dev/null 2>&1; then
            echo "podman already installed"
            exit 0
        fi
        install_pkgs \
            "podman" \
            "podman"
        ;;
    e2e)
        missing=0
        command -v podman >/dev/null 2>&1 || missing=1
        command -v qemu-system-x86_64 >/dev/null 2>&1 || missing=1
        command -v virsh >/dev/null 2>&1 || missing=1
        command -v virt-install >/dev/null 2>&1 || missing=1
        command -v sshpass >/dev/null 2>&1 || missing=1
        command -v openssl >/dev/null 2>&1 || missing=1
        command -v xorriso >/dev/null 2>&1 || missing=1
        command -v mcopy >/dev/null 2>&1 || missing=1
        if [[ "$missing" -eq 0 ]]; then
            echo "e2e prerequisites already installed"
            exit 0
        fi
        install_pkgs \
            "podman qemu-kvm libvirt-daemon-system virtinst sshpass openssl xorriso mtools" \
            "podman qemu-kvm libvirt virt-install sshpass openssl xorriso mtools"
        ;;
    *)
        echo "Unknown profile: $profile"
        exit 2
        ;;
esac
