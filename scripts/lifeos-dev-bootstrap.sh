#!/usr/bin/env bash
# lifeos-dev-bootstrap.sh — Host-side developer workstation setup for LifeOS
#
# Installs dev ergonomics on the HOST (not in the image):
#   - /etc/sudoers.d/lifeos-dev-host  (tightened sudo policy)
#   - ~/.config/systemd/user/lifeosd.service.d/10-dev-rust-log.conf
#   - /etc/systemd/system/lifeos-sentinel.service.d/10-dev-sentinel-path.conf
#     (only with --with-sentinel flag)
#
# This script MUST NOT be copied into the image. It lives at scripts/ only.
# Safe to re-run — idempotent on matching state.
#
# Exit codes:
#   0  success (all files installed or already current)
#   1  validation failure (visudo rejected sudoers syntax)
#   2  insufficient privileges (not root for privileged ops)
#   3  state drift requiring review
#   4  unexpected error (disk full, missing dep, etc.)
#
# Usage: sudo bash scripts/lifeos-dev-bootstrap.sh [--with-sentinel] [--dry-run] [--verbose] [-h|--help]

set -euo pipefail

# ── constants ─────────────────────────────────────────────────────────────────

SUDOERS_TARGET="/etc/sudoers.d/lifeos-dev-host"
SENTINEL_DROPIN="/etc/systemd/system/lifeos-sentinel.service.d/10-dev-sentinel-path.conf"
SENTINEL_SEED_SRC="/usr/local/bin/lifeos-sentinel.sh"
SENTINEL_SEED_DST="/var/lib/lifeos/bin/lifeos-sentinel.sh"
BACKUP_KEEP=5

# ── arg parsing ───────────────────────────────────────────────────────────────

WITH_SENTINEL=0
DRY_RUN=0
VERBOSE=0

usage() {
    cat <<'EOF'
Usage: sudo bash scripts/lifeos-dev-bootstrap.sh [OPTIONS]

Install LifeOS developer workstation bootstrap files on the HOST.
These files are NOT part of the image; they provide dev ergonomics.

Options:
  --with-sentinel   Also install the sentinel service override dropin that
                    redirects execution to /var/lib/lifeos/bin/lifeos-sentinel.sh
                    for local iteration without image rebuilds.
  --dry-run         Print the planned changes (diff table) and exit 0.
                    No files are written. Does not require root.
  --verbose         Print verbose progress messages.
  -h, --help        Print this help message and exit 0.

Files managed (without --with-sentinel):
  /etc/sudoers.d/lifeos-dev-host                          [requires root]
  ~/.config/systemd/user/lifeosd.service.d/10-dev-rust-log.conf

Files managed (with --with-sentinel, additional):
  /etc/systemd/system/lifeos-sentinel.service.d/10-dev-sentinel-path.conf  [requires root]
  /var/lib/lifeos/bin/lifeos-sentinel.sh                  [seeded from image, no-clobber]

Idempotent: safe to re-run. Re-running when content matches produces no changes.
Drift detection: existing files with different content are backed up first.

EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --with-sentinel)  WITH_SENTINEL=1 ;;
        --dry-run)        DRY_RUN=1 ;;
        --verbose)        VERBOSE=1 ;;
        -h|--help)        usage ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Run with -h or --help for usage." >&2
            exit 4
            ;;
    esac
    shift
done

# ── helpers ───────────────────────────────────────────────────────────────────

log_verbose() {
    [ "$VERBOSE" = "1" ] && echo "  [verbose] $*" || true
}

# Backup a file with YYYYMMDD-HHMMSS suffix and prune old backups (keep last N).
backup_file() {
    local target="$1"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    local backup="${target}.backup-${ts}"
    cp -a "$target" "$backup"
    log_verbose "Backed up $target -> $backup"
    echo "$backup"

    # Prune: keep last BACKUP_KEEP backups, delete older ones silently
    local dir base
    dir="$(dirname "$target")"
    base="$(basename "$target")"
    # shellcheck disable=SC2012
    ls -t "${dir}/${base}.backup-"* 2>/dev/null \
        | tail -n +$((BACKUP_KEEP + 1)) \
        | while IFS= read -r old; do
            rm -f "$old"
            log_verbose "Pruned old backup: $old"
        done
}

# Compute state: ABSENT / PRESENT_SAME / PRESENT_DIFF
file_state() {
    local target="$1" desired_file="$2"
    if [ ! -f "$target" ]; then
        echo "ABSENT"
    elif diff -q "$desired_file" "$target" > /dev/null 2>&1; then
        echo "PRESENT_SAME"
    else
        echo "PRESENT_DIFF"
    fi
}

# ── preflight: privilege check (skip for --dry-run) ──────────────────────────

if [ "$DRY_RUN" = "0" ] && [ "$EUID" != "0" ]; then
    echo "ERROR: This script requires root for installing sudoers and system dropins." >&2
    echo "Re-run with sudo: sudo bash scripts/lifeos-dev-bootstrap.sh $*" >&2
    exit 2
fi

# ── preflight: detect target user (uid 1000) ─────────────────────────────────

TARGET_USER="$(getent passwd | awk -F: '$3==1000{print $1; exit}')"
if [ -z "$TARGET_USER" ]; then
    echo "ERROR: Could not detect UID-1000 user via getent passwd." >&2
    exit 4
fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
RUST_LOG_DROPIN="${TARGET_HOME}/.config/systemd/user/lifeosd.service.d/10-dev-rust-log.conf"

log_verbose "Target user: $TARGET_USER (home: $TARGET_HOME)"

# ── preflight: warn if not on edge image (non-fatal) ─────────────────────────

if command -v bootc > /dev/null 2>&1 && command -v jq > /dev/null 2>&1; then
    booted_image="$(bootc status --format json 2>/dev/null | jq -r '.status.booted.image.image.image // empty' 2>/dev/null || true)"
    if [ -n "$booted_image" ] && [ "$booted_image" != "ghcr.io/hectormr206/lifeos:edge" ]; then
        echo "WARNING: Booted image is '$booted_image', not 'ghcr.io/hectormr206/lifeos:edge'."
        echo "         Bootstrap will proceed — run 'sudo bootc switch --transient ghcr.io/hectormr206/lifeos:edge' when ready."
    fi
fi

# ── build desired file content into temp files ───────────────────────────────

TMPDIR_BOOTSTRAP="$(mktemp -d /tmp/lifeos-bootstrap.XXXXXX)"
trap 'rm -rf "$TMPDIR_BOOTSTRAP"' EXIT

# --- sudoers content ---
SUDOERS_TMP="${TMPDIR_BOOTSTRAP}/lifeos-dev-host"
cat > "$SUDOERS_TMP" <<'SUDOERS_EOF'
# /etc/sudoers.d/lifeos-dev-host
# Installed by: scripts/lifeos-dev-bootstrap.sh (unify-image-kill-dev-mode)
# Managed file — do not edit manually; re-run the bootstrap script to update.
#
# SECURITY: This file grants NOPASSWD for specific LifeOS developer operations
# only. It does NOT grant: reboot, shutdown, halt, poweroff, hibernate, suspend,
# kexec, or any package manager (dnf, rpm, pip, npm).
# Bounded cat/ls paths per Q-SPEC-1 (design: sdd/unify-image-kill-dev-mode/design).

Cmnd_Alias LIFEOS_DEV_BOOTC = \
    /usr/bin/bootc usroverlay, \
    /usr/bin/bootc upgrade, \
    /usr/bin/bootc rollback, \
    /usr/bin/bootc switch ghcr.io/hectormr206/lifeos\:*

Cmnd_Alias LIFEOS_DEV_SYSTEMD = \
    /usr/bin/systemctl daemon-reload, \
    /usr/bin/systemctl restart lifeosd.service, \
    /usr/bin/systemctl start lifeosd.service, \
    /usr/bin/systemctl stop lifeosd.service, \
    /usr/bin/systemctl status lifeosd.service, \
    /usr/bin/systemctl restart lifeos-sentinel.service, \
    /usr/bin/systemctl start lifeos-sentinel.service, \
    /usr/bin/systemctl stop lifeos-sentinel.service, \
    /usr/bin/systemctl status lifeos-sentinel.service, \
    /usr/bin/systemctl start lifeos-update-check.service, \
    /usr/bin/systemctl start lifeos-update-stage.service

Cmnd_Alias LIFEOS_DEV_INSTALL = \
    /usr/bin/install -D -m 644 * /etc/lifeos/*, \
    /usr/bin/install -D -m 644 * /etc/systemd/system/lifeos-*, \
    /usr/bin/install -D -m 644 * /var/lib/lifeos/*, \
    /usr/bin/install -D -m 755 * /usr/local/bin/lifeos-*, \
    /usr/bin/chmod 0440 /etc/sudoers.d/lifeos-dev-host, \
    /usr/bin/chown root\:root /etc/sudoers.d/lifeos-dev-host

Cmnd_Alias LIFEOS_DEV_READ_CAT = \
    /usr/bin/cat /etc/lifeos/*, \
    /usr/bin/cat /etc/sudoers.d/lifeos-*, \
    /usr/bin/cat /etc/systemd/system/*.service, \
    /usr/bin/cat /etc/systemd/system/*.timer, \
    /usr/bin/cat /etc/systemd/system/*.service.d/*.conf, \
    /usr/bin/cat /etc/systemd/user/*.service, \
    /usr/bin/cat /etc/systemd/user/*.service.d/*.conf, \
    /usr/bin/cat /etc/modules-load.d/*.conf, \
    /usr/bin/cat /etc/modprobe.d/*.conf, \
    /usr/bin/cat /var/lib/lifeos/*, \
    /usr/bin/cat /var/log/lifeos/*, \
    /usr/bin/cat /proc/*/status, \
    /usr/bin/cat /proc/*/cmdline, \
    /usr/bin/cat /proc/*/maps, \
    /usr/bin/cat /proc/cmdline, \
    /usr/bin/cat /proc/meminfo, \
    /usr/bin/cat /proc/cpuinfo, \
    /usr/bin/cat /proc/loadavg, \
    /usr/bin/cat /proc/mounts, \
    /usr/bin/cat /proc/*/stat, \
    /usr/bin/cat /sys/class/thermal/*/temp, \
    /usr/bin/cat /sys/class/power_supply/*/*, \
    /usr/bin/cat /sys/class/drm/card*/device/uevent, \
    /usr/bin/cat /sys/kernel/security/*, \
    /usr/bin/cat /sys/fs/selinux/enforce, \
    /usr/bin/cat /sys/fs/selinux/avc/*, \
    /usr/bin/cat /run/systemd/system/*, \
    /usr/bin/cat /run/user/*/systemd/user/*

Cmnd_Alias LIFEOS_DEV_READ_LS = \
    /usr/bin/ls /etc/lifeos, \
    /usr/bin/ls /etc/lifeos/*, \
    /usr/bin/ls /etc/systemd/system, \
    /usr/bin/ls /etc/systemd/system/*, \
    /usr/bin/ls /etc/systemd/system/*.service.d, \
    /usr/bin/ls /etc/systemd/user, \
    /usr/bin/ls /etc/systemd/user/*, \
    /usr/bin/ls /etc/systemd/user/*.service.d, \
    /usr/bin/ls /etc/sudoers.d, \
    /usr/bin/ls /var/lib/lifeos, \
    /usr/bin/ls /var/lib/lifeos/*, \
    /usr/bin/ls /var/log/lifeos, \
    /usr/bin/ls /var/log/lifeos/*, \
    /usr/bin/ls /usr/local/bin, \
    /usr/bin/ls /usr/lib/systemd/system, \
    /usr/bin/ls /etc/modules-load.d, \
    /usr/bin/ls /etc/modprobe.d

%lifeos ALL=(root) NOPASSWD: LIFEOS_DEV_BOOTC, LIFEOS_DEV_SYSTEMD, LIFEOS_DEV_INSTALL, LIFEOS_DEV_READ_CAT, LIFEOS_DEV_READ_LS
SUDOERS_EOF

# --- RUST_LOG dropin content ---
RUSTLOG_TMP="${TMPDIR_BOOTSTRAP}/10-dev-rust-log.conf"
cat > "$RUSTLOG_TMP" <<'RUSTLOG_EOF'
[Service]
Environment=RUST_LOG=debug
RUSTLOG_EOF

# --- sentinel dropin content ---
SENTINEL_TMP="${TMPDIR_BOOTSTRAP}/10-dev-sentinel-path.conf"
cat > "$SENTINEL_TMP" <<'SENTINEL_EOF'
[Service]
ExecStart=
ExecStart=/bin/bash -c 'exec "$( [ -f /var/lib/lifeos/bin/lifeos-sentinel.sh ] && echo /var/lib/lifeos/bin/lifeos-sentinel.sh || echo /usr/local/bin/lifeos-sentinel.sh )"'
SENTINEL_EOF

# ── compute states ────────────────────────────────────────────────────────────

state_sudoers="$(file_state "$SUDOERS_TARGET" "$SUDOERS_TMP")"
state_rustlog="$(file_state "$RUST_LOG_DROPIN" "$RUSTLOG_TMP")"

if [ "$WITH_SENTINEL" = "1" ]; then
    state_sentinel="$(file_state "$SENTINEL_DROPIN" "$SENTINEL_TMP")"
elif [ -f "$SENTINEL_DROPIN" ]; then
    state_sentinel="PRESENT_DIFF"  # exists but should be removed
else
    state_sentinel="ABSENT_SKIP"   # absent and skipped
fi

# ── dry-run: print diff table and exit ───────────────────────────────────────

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "=== dry-run: planned changes (no files written) ==="
    echo ""
    printf "  %-70s %s\n" "FILE" "PLANNED ACTION"
    printf "  %-70s %s\n" "----" "--------------"

    case "$state_sudoers" in
        ABSENT)        printf "  %-70s %s\n" "$SUDOERS_TARGET" "INSTALL (new)" ;;
        PRESENT_SAME)  printf "  %-70s %s\n" "$SUDOERS_TARGET" "already up-to-date (no change)" ;;
        PRESENT_DIFF)  printf "  %-70s %s\n" "$SUDOERS_TARGET" "UPDATE (backup existing)" ;;
    esac

    case "$state_rustlog" in
        ABSENT)        printf "  %-70s %s\n" "$RUST_LOG_DROPIN" "INSTALL (new)" ;;
        PRESENT_SAME)  printf "  %-70s %s\n" "$RUST_LOG_DROPIN" "already up-to-date (no change)" ;;
        PRESENT_DIFF)  printf "  %-70s %s\n" "$RUST_LOG_DROPIN" "UPDATE (backup existing)" ;;
    esac

    case "$state_sentinel" in
        ABSENT)         printf "  %-70s %s\n" "$SENTINEL_DROPIN" "INSTALL (new, --with-sentinel)" ;;
        PRESENT_SAME)   printf "  %-70s %s\n" "$SENTINEL_DROPIN" "already up-to-date (no change)" ;;
        PRESENT_DIFF)
            if [ "$WITH_SENTINEL" = "1" ]; then
                printf "  %-70s %s\n" "$SENTINEL_DROPIN" "UPDATE (backup existing)"
            else
                printf "  %-70s %s\n" "$SENTINEL_DROPIN" "REMOVE (backup existing)"
            fi
            ;;
        ABSENT_SKIP)    printf "  %-70s %s\n" "$SENTINEL_DROPIN" "skipped (use --with-sentinel to install)" ;;
    esac

    echo ""
    echo "  (dry-run complete — no changes made)"
    exit 0
fi

# ── apply: sudoers (requires root, already verified above) ───────────────────

SUMMARY_SUDOERS=""
SUMMARY_RUSTLOG=""
SUMMARY_SENTINEL=""

install_sudoers() {
    # Atomic: stage → visudo -cf → backup existing → mv into place
    local staged
    staged="$(mktemp --tmpdir=/tmp .lifeos-dev-host.XXXX)"
    trap 'rm -f "$staged"' RETURN

    cp "$SUDOERS_TMP" "$staged"
    chmod 0440 "$staged"
    chown root:root "$staged"

    if ! visudo -cf "$staged" > /dev/null 2>&1; then
        rm -f "$staged"
        echo "ERROR: visudo rejected sudoers content. Aborting — $SUDOERS_TARGET NOT modified." >&2
        exit 1
    fi

    local backup_path=""
    if [ -f "$SUDOERS_TARGET" ]; then
        backup_path="$(backup_file "$SUDOERS_TARGET")"
    fi

    mv -f "$staged" "$SUDOERS_TARGET"
    chmod 0440 "$SUDOERS_TARGET"
    chown root:root "$SUDOERS_TARGET"

    if [ -n "$backup_path" ]; then
        SUMMARY_SUDOERS="updated (backup: $backup_path)"
    else
        SUMMARY_SUDOERS="installed"
    fi
}

case "$state_sudoers" in
    ABSENT|PRESENT_DIFF)
        log_verbose "Installing sudoers: $SUDOERS_TARGET"
        install_sudoers
        ;;
    PRESENT_SAME)
        SUMMARY_SUDOERS="already up-to-date"
        log_verbose "Sudoers already up-to-date: $SUDOERS_TARGET"
        ;;
esac

# ── apply: RUST_LOG user dropin (no root required) ───────────────────────────

install_rustlog() {
    local parent
    parent="$(dirname "$RUST_LOG_DROPIN")"
    install -d -m 0755 "$parent"

    local backup_path=""
    if [ -f "$RUST_LOG_DROPIN" ]; then
        backup_path="$(backup_file "$RUST_LOG_DROPIN")"
    fi

    install -m 644 "$RUSTLOG_TMP" "$RUST_LOG_DROPIN"
    chown "${TARGET_USER}:${TARGET_USER}" "$RUST_LOG_DROPIN"
    chown "${TARGET_USER}:${TARGET_USER}" "$parent"

    if [ -n "$backup_path" ]; then
        SUMMARY_RUSTLOG="updated (backup: $backup_path)"
    else
        SUMMARY_RUSTLOG="installed"
    fi
}

case "$state_rustlog" in
    ABSENT|PRESENT_DIFF)
        log_verbose "Installing RUST_LOG dropin: $RUST_LOG_DROPIN"
        install_rustlog
        ;;
    PRESENT_SAME)
        SUMMARY_RUSTLOG="already up-to-date"
        log_verbose "RUST_LOG dropin already up-to-date: $RUST_LOG_DROPIN"
        ;;
esac

# ── apply: sentinel dropin ────────────────────────────────────────────────────

install_sentinel() {
    local parent
    parent="$(dirname "$SENTINEL_DROPIN")"
    install -d -m 0755 "$parent"

    local backup_path=""
    if [ -f "$SENTINEL_DROPIN" ]; then
        backup_path="$(backup_file "$SENTINEL_DROPIN")"
    fi

    install -m 644 "$SENTINEL_TMP" "$SENTINEL_DROPIN"

    if [ -n "$backup_path" ]; then
        SUMMARY_SENTINEL="installed (backup: $backup_path)"
    else
        SUMMARY_SENTINEL="installed"
    fi

    # Seed /var/lib/lifeos/bin/lifeos-sentinel.sh from image copy (no-clobber)
    if [ -f "$SENTINEL_SEED_SRC" ]; then
        install -d -m 0755 "$(dirname "$SENTINEL_SEED_DST")"
        if [ ! -f "$SENTINEL_SEED_DST" ]; then
            cp --no-clobber "$SENTINEL_SEED_SRC" "$SENTINEL_SEED_DST"
            log_verbose "Seeded sentinel: $SENTINEL_SEED_DST"
        else
            log_verbose "Sentinel seed already present: $SENTINEL_SEED_DST"
        fi
    else
        echo "WARNING: $SENTINEL_SEED_SRC not found — sentinel seed skipped." \
             "The dropin will fall back to the image copy on start." >&2
    fi
}

remove_sentinel() {
    local backup_path=""
    if [ -f "$SENTINEL_DROPIN" ]; then
        backup_path="$(backup_file "$SENTINEL_DROPIN")"
        rm -f "$SENTINEL_DROPIN"
        SUMMARY_SENTINEL="removed (backup: $backup_path)"
    fi
}

if [ "$WITH_SENTINEL" = "1" ]; then
    case "$state_sentinel" in
        ABSENT|PRESENT_DIFF)
            log_verbose "Installing sentinel dropin: $SENTINEL_DROPIN"
            install_sentinel
            ;;
        PRESENT_SAME)
            SUMMARY_SENTINEL="already up-to-date"
            log_verbose "Sentinel dropin already up-to-date: $SENTINEL_DROPIN"
            ;;
    esac
else
    case "$state_sentinel" in
        PRESENT_DIFF)
            # Exists from a prior --with-sentinel run; must remove
            log_verbose "Removing stale sentinel dropin: $SENTINEL_DROPIN"
            remove_sentinel
            ;;
        ABSENT_SKIP)
            SUMMARY_SENTINEL="skipped (use --with-sentinel to install)"
            ;;
        *)
            SUMMARY_SENTINEL="skipped (use --with-sentinel to install)"
            ;;
    esac
fi

# ── post-apply: reload user units (unless dry-run, already excluded above) ───

if [ -n "$TARGET_USER" ] && id "$TARGET_USER" > /dev/null 2>&1; then
    uid_1000="$(id -u "$TARGET_USER")"
    if [ -d "/run/user/${uid_1000}/systemd" ]; then
        log_verbose "Reloading user systemd units for $TARGET_USER..."
        runuser -u "$TARGET_USER" -- systemctl --user daemon-reload 2>/dev/null || true
        runuser -u "$TARGET_USER" -- systemctl --user try-restart lifeosd.service 2>/dev/null || true
    fi
fi

# ── summary block ─────────────────────────────────────────────────────────────

echo ""
echo "=== LifeOS Dev Bootstrap — Summary ==="
echo ""
printf "  %-65s %s\n" "$SUDOERS_TARGET" "$SUMMARY_SUDOERS"
printf "  %-65s %s\n" "$RUST_LOG_DROPIN" "$SUMMARY_RUSTLOG"
printf "  %-65s %s\n" "$SENTINEL_DROPIN" "${SUMMARY_SENTINEL:-skipped}"
echo ""
echo "Migration complete. Reboot at your convenience to converge on next image fetch."
echo ""
echo "Next step (run manually when ready):"
echo "  sudo bootc switch --transient ghcr.io/hectormr206/lifeos:edge"
echo ""
