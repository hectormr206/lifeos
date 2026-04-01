#!/bin/bash
# LifeOS GRUB Password Protection
# Protects boot parameter editing (prevents init=/bin/bash attack).
# Normal boot still works without password — only editing requires it.
#
# Usage:
#   sudo lifeos-grub-password.sh set       # Set/change GRUB password
#   sudo lifeos-grub-password.sh remove     # Remove GRUB password
#   sudo lifeos-grub-password.sh status     # Check if password is set
#
# On bootc: writes to /boot/grub2/user.cfg (safe, not in /usr)

set -euo pipefail

USER_CFG="/boot/grub2/user.cfg"
CUSTOM_CFG="/boot/grub2/custom.cfg"

usage() {
    echo "Usage: $0 {set|remove|status}"
    echo "  set    — Set or change GRUB superuser password"
    echo "  remove — Remove GRUB password protection"
    echo "  status — Check if GRUB password is configured"
    exit 1
}

grub_password_status() {
    if grep -q "GRUB_PASSWORD_HASH" "$USER_CFG" 2>/dev/null && \
       grep -q "set superusers" "$CUSTOM_CFG" 2>/dev/null; then
        echo "[grub-password] GRUB password protection is ACTIVE"
        return 0
    else
        echo "[grub-password] GRUB password protection is NOT configured"
        return 1
    fi
}

grub_password_set() {
    echo "[grub-password] Setting GRUB boot protection password..."
    echo "This password protects boot parameter editing (not normal boot)."
    echo ""

    # Generate password hash
    local hash
    hash=$(grub2-mkpasswd-pbkdf2 | grep "grub.pbkdf2" | awk '{print $NF}')

    if [ -z "$hash" ]; then
        echo "[grub-password] ERROR: Failed to generate password hash"
        exit 1
    fi

    # Store hash in user.cfg
    if [ -f "$USER_CFG" ]; then
        grep -v "GRUB_PASSWORD_HASH" "$USER_CFG" > "${USER_CFG}.tmp" || true
        mv "${USER_CFG}.tmp" "$USER_CFG"
    fi
    echo "GRUB_PASSWORD_HASH=\"${hash}\"" >> "$USER_CFG"

    # Create custom.cfg with superuser config
    # --unrestricted on menuentry allows normal boot without password
    cat > "$CUSTOM_CFG" << GRUBCFG
# LifeOS GRUB Password Protection
# Normal boot entries are unrestricted — password only for editing
set superusers="lifeos"
password_pbkdf2 lifeos ${hash}
GRUBCFG

    echo ""
    echo "[grub-password] GRUB password protection ENABLED"
    echo "[grub-password] Normal boot works without password"
    echo "[grub-password] Editing boot parameters requires the password"
}

grub_password_remove() {
    echo "[grub-password] Removing GRUB password protection..."

    if [ -f "$USER_CFG" ]; then
        grep -v "GRUB_PASSWORD_HASH" "$USER_CFG" > "${USER_CFG}.tmp" || true
        mv "${USER_CFG}.tmp" "$USER_CFG"
    fi

    if [ -f "$CUSTOM_CFG" ]; then
        grep -v "superusers\|password_pbkdf2\|LifeOS GRUB Password\|Normal boot\|Editing boot" "$CUSTOM_CFG" > "${CUSTOM_CFG}.tmp" || true
        mv "${CUSTOM_CFG}.tmp" "$CUSTOM_CFG"
        # Remove if empty
        if [ ! -s "$CUSTOM_CFG" ]; then
            rm -f "$CUSTOM_CFG"
        fi
    fi

    echo "[grub-password] GRUB password protection REMOVED"
}

[ $# -lt 1 ] && usage

case "$1" in
    set)    grub_password_set ;;
    remove) grub_password_remove ;;
    status) grub_password_status ;;
    *)      usage ;;
esac
