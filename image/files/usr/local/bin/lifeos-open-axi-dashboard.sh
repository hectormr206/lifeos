#!/usr/bin/env sh
set -eu

if [ "${LIFEOS_SKIP_AXI_WELCOME:-0}" = "1" ]; then
    exit 0
fi

dashboard_port="${LIFEOS_DASHBOARD_PORT:-8081}"
dashboard_base="http://127.0.0.1:${dashboard_port}/dashboard/"
bootstrap_url="http://127.0.0.1:${dashboard_port}/dashboard/bootstrap"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
marker_dir="${state_home}/lifeos"
marker_file="${marker_dir}/axi-experience-version"
channel_file="/etc/lifeos/channel"
boot_mode=0
once_per_version=0

while [ $# -gt 0 ]; do
    case "$1" in
        --boot)
            boot_mode=1
            ;;
        --once-per-version)
            once_per_version=1
            ;;
    esac
    shift
done

version_key="lifeos"
if [ -r "${channel_file}" ]; then
    version_key="$(
        awk -F= '
            /^VCS_REF=/ { gsub(/"/, "", $2); print $2; found=1; exit }
            /^BUILD_DATE=/ { gsub(/"/, "", $2); fallback=$2 }
            END {
                if (!found && fallback != "") {
                    print fallback
                }
            }
        ' "${channel_file}"
    )"
fi
[ -n "${version_key}" ] || version_key="lifeos"

mkdir -p "${marker_dir}"

if [ "${once_per_version}" -eq 1 ] && [ -r "${marker_file}" ]; then
    if [ "$(cat "${marker_file}")" = "${version_key}" ]; then
        exit 0
    fi
fi

query=""
if [ "${boot_mode}" -eq 1 ]; then
    query="?boot=1"
fi

dashboard_url="${dashboard_base}${query}"

i=0
while [ "${i}" -lt 45 ]; do
    if curl -fsS "${bootstrap_url}" >/dev/null 2>&1; then
        [ "${once_per_version}" -eq 1 ] && printf '%s' "${version_key}" > "${marker_file}"
        if command -v xdg-open >/dev/null 2>&1; then
            xdg-open "${dashboard_url}" >/dev/null 2>&1 &
            exit 0
        fi
        if command -v gio >/dev/null 2>&1; then
            gio open "${dashboard_url}" >/dev/null 2>&1 &
            exit 0
        fi
        exit 1
    fi
    i=$((i + 1))
    sleep 2
done

exit 0
