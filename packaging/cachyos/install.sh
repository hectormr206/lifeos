#!/usr/bin/env bash
# install.sh — One-shot installer for the LifeOS runtime on CachyOS / Arch.
#
# Loops through the 5 PKGBUILDs in dependency order, runs `makepkg -si` for
# each, and verifies the result. Idempotent — re-running on an existing
# install will simply skip already-installed packages (pacman handles this).
#
# Usage:
#   bash install.sh              # interactive (sudo prompts as needed)
#   bash install.sh --check      # dry-run; print what WOULD be done
#   bash install.sh --no-deps    # skip the build-dep check
#   bash install.sh --help       # show help
#
# Exit codes:
#   0 — all packages installed (or already up to date)
#   1 — one or more makepkg invocations failed
#   2 — pre-flight failed (unsupported distro, missing core deps)

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Five LifeOS packages in dependency order. lifeos-containers MUST come first
# (creates the `lifeos` system user + tmpfiles entries the rest depend on).
PACKAGES=(
    lifeos-containers
    lifeos-cli
    lifeos-daemon
    lifeos-desktop
    lifeos-runtime
)

# Build deps that every PKGBUILD assumes are present on the host.
BUILD_DEPS=(
    base-devel
    rust
    cargo
    clang
    pkg-config
    gtk4
    libadwaita
    dbus
    pipewire
    wayland
    openssl
    sqlite
)

# ── Helpers ───────────────────────────────────────────────────────────────────

color_red()    { printf '\033[31m%s\033[0m' "$1"; }
color_green()  { printf '\033[32m%s\033[0m' "$1"; }
color_yellow() { printf '\033[33m%s\033[0m' "$1"; }
color_bold()   { printf '\033[1m%s\033[0m' "$1"; }

log_step() { printf '%s %s\n' "$(color_bold "==>")" "$1"; }
log_ok()   { printf '  %s %s\n' "$(color_green "✓")" "$1"; }
log_warn() { printf '  %s %s\n' "$(color_yellow "⚠")" "$1"; }
log_err()  { printf '  %s %s\n' "$(color_red "✗")" "$1" >&2; }

usage() {
    cat <<'EOF'
LifeOS CachyOS installer

Usage:
  install.sh [OPTIONS]

Options:
  --check       Print what would be done without invoking makepkg
  --no-deps     Skip the pre-flight build-deps check
  -h, --help    Show this message

Build order (dependency-aware):
  1. lifeos-containers (creates system user + tmpfiles)
  2. lifeos-cli
  3. lifeos-daemon
  4. lifeos-desktop
  5. lifeos-runtime (meta-package)

After install, run `life init` to enable services and verify the dashboard.
See ../../docs/operations/runtime-install.md for full documentation.
EOF
}

is_arch_based() {
    [[ -r /etc/os-release ]] || return 1
    # Match ID=arch | ID=cachyos | ID_LIKE containing "arch"
    grep -qE '^(ID|ID_LIKE)=.*(arch|cachyos)' /etc/os-release
}

check_build_deps() {
    local missing=()
    local pkg
    for pkg in "${BUILD_DEPS[@]}"; do
        if ! pacman -Qi "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        log_warn "Missing build dependencies: ${missing[*]}"
        log_warn "Install them with: sudo pacman -S --needed ${missing[*]}"
        return 1
    fi
    log_ok "build dependencies present"
    return 0
}

install_package() {
    local pkg="$1"
    local pkg_dir="${SCRIPT_DIR}/${pkg}"

    if [[ ! -d "$pkg_dir" ]]; then
        log_err "Package directory not found: $pkg_dir"
        return 1
    fi

    if [[ ! -f "${pkg_dir}/PKGBUILD" ]]; then
        log_err "PKGBUILD missing in: $pkg_dir"
        return 1
    fi

    log_step "Installing $(color_bold "$pkg")"

    if [[ "$DRY_RUN" == "1" ]]; then
        printf '  (dry-run) cd %s && makepkg -si --noconfirm\n' "$pkg_dir"
        return 0
    fi

    (
        cd "$pkg_dir"
        makepkg -si --noconfirm
    ) || {
        log_err "makepkg failed for $pkg"
        return 1
    }

    log_ok "$pkg installed"
}

# ── Argument parsing ──────────────────────────────────────────────────────────

DRY_RUN=0
SKIP_DEPS_CHECK=0

while (( $# > 0 )); do
    case "$1" in
        --check)    DRY_RUN=1; shift ;;
        --no-deps)  SKIP_DEPS_CHECK=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          log_err "Unknown option: $1"; usage >&2; exit 2 ;;
    esac
done

# ── Pre-flight ────────────────────────────────────────────────────────────────

log_step "Pre-flight checks"

if ! is_arch_based; then
    log_err "Unsupported distro (need Arch-based — CachyOS, Arch, Manjaro, EndeavourOS)"
    log_err "See /etc/os-release for the detected ID."
    exit 2
fi
log_ok "Arch-based host detected"

if ! command -v makepkg >/dev/null 2>&1; then
    log_err "makepkg not found — install base-devel: sudo pacman -S base-devel"
    exit 2
fi
log_ok "makepkg available"

if (( SKIP_DEPS_CHECK == 0 )); then
    if ! check_build_deps; then
        log_err "Pre-flight failed — install the missing dependencies and re-run."
        log_err "Or run with --no-deps to skip this check (at your own risk)."
        exit 2
    fi
fi

# ── Install loop ──────────────────────────────────────────────────────────────

log_step "Installing $(color_bold "${#PACKAGES[@]}") packages in dependency order"

FAILED=()
for pkg in "${PACKAGES[@]}"; do
    if ! install_package "$pkg"; then
        FAILED+=("$pkg")
    fi
done

# ── Report ────────────────────────────────────────────────────────────────────

printf '\n'
if (( ${#FAILED[@]} == 0 )); then
    log_step "$(color_green "All packages installed successfully")"
    if (( DRY_RUN == 0 )); then
        printf '\nNext step: %s\n' "$(color_bold "life init")"
        printf 'Run %s to enable services and verify the dashboard.\n' "$(color_bold "life init")"
    fi
    exit 0
else
    log_step "$(color_red "${#FAILED[@]} package(s) failed: ${FAILED[*]}")"
    printf 'Review the output above and re-run %s after fixing.\n' "$(color_bold "bash install.sh")"
    exit 1
fi
