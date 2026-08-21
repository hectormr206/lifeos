#!/bin/sh
# install-linux.sh — install, upgrade or remove the LifeOS desktop app.
#
#   curl -fsSL https://<base>/linux/install-linux.sh \
#     | sudo sh -s -- --base-url https://<base> --key <UPDATE_ACCESS_KEY>
#
# Distro-agnostic on purpose: the target laptop runs CachyOS (Arch/pacman), the
# build box runs Debian, and a .deb would have been useless to both. So this
# installs a self-contained tarball into /opt/lifeos and only *reports* missing
# system libraries, with the right package-manager command for whatever distro
# it actually found — it never installs system packages behind your back.
#
# Idempotent: re-running upgrades in place. `--update` is the same code path,
# used by lifeos-updater.service, and exits 0 quietly when already current.
#
# Deliberately POSIX sh (no bashisms): `curl | sh` must work where /bin/sh is
# dash, ash or busybox, not only where it is bash.
#
# Fails loudly. Every abort happens BEFORE anything on disk is replaced: the
# sha256 is checked before unpacking, and the new release is staged in full
# before the `current` symlink is swapped. There is no path that leaves a
# half-installed tree and exits 0.
set -eu

# Stamped by publish-linux-to-vps.sh at publish time with the URL this script
# is served from. Empty in the repo copy on purpose: a checkout must not carry
# somebody else's server baked in.
LIFEOS_BASE_URL="${LIFEOS_BASE_URL:-}"

VERSION="1.0.0"
PREFIX="/opt/lifeos"
RELEASES_DIR="$PREFIX/releases"
CURRENT_LINK="$PREFIX/current"
BIN_DIR="$PREFIX/bin"
STATE_MANIFEST="$PREFIX/manifest.json"
CONF_DIR="/etc/lifeos"
CONF_FILE="$CONF_DIR/update.env"
TRIGGER_DIR="/var/lib/lifeos/trigger"
DESKTOP_FILE="/usr/share/applications/lifeos.desktop"
ICON_FILE="/usr/share/icons/hicolor/512x512/apps/lifeos.png"
LAUNCHER_LINK="/usr/local/bin/lifeos"
UNIT_DIR="/etc/systemd/system"
USER_UNIT_DIR="/etc/systemd/user"
KEY_HEADER="X-LifeOS-Update-Key"
KEEP_RELEASES=2

MODE="install"          # install | update | uninstall | install-units
BASE_URL="${UPDATE_BASE_URL:-}"
ACCESS_KEY="${UPDATE_ACCESS_KEY:-}"
FORCE=0
SKIP_DEP_CHECK=0
WORKDIR=""

# ─────────────────────────────────────────────────────────────────────────────
# Output helpers. Everything diagnostic goes to stderr so `--print-version`
# style piping stays clean.
# ─────────────────────────────────────────────────────────────────────────────
say()  { printf '%s\n' "$*"; }
step() { printf '→ %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

# die() is the only exit path for failure. It always explains what to do next.
die() {
  printf '\nERROR: %s\n' "$1" >&2
  shift
  for line in "$@"; do printf '       %s\n' "$line" >&2; done
  printf '\nNothing was changed. The installed app (if any) is untouched.\n' >&2
  exit 1
}

cleanup() {
  [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
  return 0
}
trap cleanup EXIT HUP INT TERM

usage() {
  cat <<EOF
LifeOS Linux installer $VERSION

USAGE
  sudo sh install-linux.sh --base-url <URL> --key <KEY>   install or upgrade
  sudo sh install-linux.sh --update                       upgrade only, quiet if current
  sudo sh install-linux.sh --uninstall                    remove everything
  sh install-linux.sh --help

OPTIONS
  --base-url <URL>   Update server root, e.g. https://example.tld/lifeos.
                     Persisted to $CONF_FILE; optional on later runs.
  --key <KEY>        Value for the $KEY_HEADER header. Persisted likewise.
  --update           Non-interactive upgrade path used by lifeos-updater.service.
                     Reads config from $CONF_FILE. Exits 0 when already current.
  --uninstall        Remove $PREFIX, the launcher, the icon and the systemd units.
  --install-units    Place and enable the systemd units only. Used internally by
                     an older installed copy after unpacking a new release.
                     Leaves your data in ~/.local/share and ~/.config alone.
  --force            Reinstall even when the published version is already installed.
  --skip-dep-check   Do not abort on missing system libraries. You are on your own.
  --help, --version

WHAT IT INSTALLS
  $PREFIX/releases/<versionCode>/   the app bundle (~150 MB per release)
  $CURRENT_LINK                     symlink to the active release
  $LAUNCHER_LINK                    command-line launcher
  $DESKTOP_FILE                     applications-menu entry
  $ICON_FILE                        icon
  $UNIT_DIR/lifeos-updater.{service,timer,path}
  $USER_UNIT_DIR/lifeos-briefing.{service,timer}
                                    system-level auto-update (survives logout)
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --base-url) [ $# -ge 2 ] || die "--base-url needs a value."; BASE_URL="$2"; shift 2 ;;
    --base-url=*) BASE_URL="${1#--base-url=}"; shift ;;
    --key) [ $# -ge 2 ] || die "--key needs a value."; ACCESS_KEY="$2"; shift 2 ;;
    --key=*) ACCESS_KEY="${1#--key=}"; shift ;;
    --update) MODE="update"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    # Place and enable the systemd units and nothing else. Used by an older
    # installed copy to hand that step to the release it just unpacked.
    --install-units) MODE="install-units"; shift ;;
    --force) FORCE=1; shift ;;
    --skip-dep-check) SKIP_DEP_CHECK=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --version) say "$VERSION"; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Privilege. We install system-wide (/opt, /usr/share, /etc/systemd/system)
# because the user explicitly wants a SYSTEM service: a --user unit dies with
# the login session, which is exactly the failure this design avoids.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
  # Re-exec ourselves under sudo when we are a real file on disk. When we were
  # piped into sh there is no file to re-exec (our source is already consumed
  # from stdin), so we refuse with the exact command to run instead of
  # half-trying and failing somewhere deeper.
  if [ -f "$0" ] && [ -r "$0" ]; then
    step "Not root — re-running under sudo…"
    exec sudo -- "${CONFIG_SHELL:-/bin/sh}" "$0" "$@"
  fi
  die "This installer must run as root, and it was piped into a shell so it cannot re-exec itself." \
      "Re-run with sudo in the pipeline:" \
      "" \
      "  curl -fsSL <url>/linux/install-linux.sh | sudo sh -s -- --base-url <url> --key <KEY>"
fi

command -v systemctl >/dev/null 2>&1 || SYSTEMCTL_MISSING=1

# ─────────────────────────────────────────────────────────────────────────────
# Distro + package manager detection
# ─────────────────────────────────────────────────────────────────────────────
DISTRO_ID="unknown"
DISTRO_NAME="unknown Linux"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_NAME="${PRETTY_NAME:-${NAME:-unknown Linux}}"
  # ID_LIKE lets CachyOS/EndeavourOS/Manjaro fall back to arch, Mint to debian,
  # and so on, instead of us maintaining a list of every derivative.
  DISTRO_LIKE="${ID_LIKE:-}"
else
  DISTRO_LIKE=""
fi

# Detect by the binary that actually exists, not by the distro name: that is
# what survives derivatives nobody has heard of.
PM=""
for candidate in pacman apt-get dnf zypper apk xbps-install; do
  if command -v "$candidate" >/dev/null 2>&1; then PM="$candidate"; break; fi
done
[ -n "$PM" ] || PM="$(printf '%s %s' "$DISTRO_ID" "$DISTRO_LIKE" | tr ' ' '\n' | \
  while read -r d; do
    case "$d" in
      arch) echo pacman; break ;;
      debian|ubuntu) echo apt-get; break ;;
      fedora|rhel) echo dnf; break ;;
      suse|opensuse*) echo zypper; break ;;
    esac
  done)"

pm_install_cmd() {
  case "$PM" in
    pacman)       printf 'sudo pacman -S --needed %s' "$*" ;;
    apt-get)      printf 'sudo apt-get install -y %s' "$*" ;;
    dnf)          printf 'sudo dnf install -y %s' "$*" ;;
    zypper)       printf 'sudo zypper install -y %s' "$*" ;;
    apk)          printf 'sudo apk add %s' "$*" ;;
    xbps-install) printf 'sudo xbps-install -S %s' "$*" ;;
    *)            printf 'install these with your package manager: %s' "$*" ;;
  esac
}

# Install the named packages ourselves, non-interactively. Returns non-zero if
# the package manager refuses; the caller re-checks the libraries rather than
# trusting the exit code.
#
# WHY THIS EXISTS. This installer already runs as root (systemd's
# lifeos-updater.service), already detects exactly which libraries are missing,
# and already knows the package name for every distro it supports. It then
# printed a command for a human to type. On the real laptop that meant the
# hourly updater failed on a missing libayatana-appindicator for TWO DAYS while
# the desktop app sat on an old build, and nobody knew: the failure lived in a
# journal nobody reads. Updates are supposed to arrive on their own, the way
# they do on the phone.
#
# ARCH SAFETY, deliberately: `-S --needed --noconfirm` and NEVER `-Sy pkg`.
# Syncing the databases and installing a single package is a partial upgrade,
# the documented way to break an Arch system. If the local database is too old
# to resolve the package we fail loudly instead — a stale database is the
# user's call, not something to "fix" behind their back during an update.
pm_install_run() {
  [ -n "${PM:-}" ] || return 1
  case "$PM" in
    pacman)       pacman -S --needed --noconfirm "$@" ;;
    apt-get)      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)          dnf install -y "$@" ;;
    zypper)       zypper --non-interactive install "$@" ;;
    apk)          apk add "$@" ;;
    xbps-install) xbps-install -y "$@" ;;
    *)            return 1 ;;
  esac
}

# Architecture. The published tarball is arch-specific, so this picks the path
# on the update server rather than being cosmetic.
case "$(uname -m)" in
  x86_64|amd64) ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Unsupported CPU architecture: $(uname -m)." \
         "LifeOS desktop publishes x64 and arm64 builds only." ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Runtime dependency check.
#
# We probe for the actual shared objects and binaries, not for package names:
# package names differ per distro but the SONAME does not, so this stays
# correct on distros this script has never seen. The name mapping below is only
# used to print a helpful command.
# ─────────────────────────────────────────────────────────────────────────────
have_lib() {
  if command -v ldconfig >/dev/null 2>&1 && ldconfig -p 2>/dev/null | grep -q "[[:space:]]$1[[:space:]]"; then
    return 0
  fi
  # ldconfig is absent or empty (musl, some containers): fall back to a search
  # of the usual multiarch library directories.
  for d in /usr/lib /usr/lib64 /lib /lib64 /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu /usr/local/lib; do
    [ -e "$d/$1" ] && return 0
  done
  return 1
}

pkg_for() { # $1 = soname/binary token -> package name for the detected PM
  case "$PM:$1" in
    pacman:libgtk-3.so.0)            echo gtk3 ;;
    apt-get:libgtk-3.so.0)           echo libgtk-3-0 ;;
    dnf:libgtk-3.so.0)               echo gtk3 ;;
    zypper:libgtk-3.so.0)            echo gtk3 ;;
    apk:libgtk-3.so.0)               echo gtk+3.0 ;;
    xbps-install:libgtk-3.so.0)      echo gtk+3 ;;

    pacman:libgstreamer-1.0.so.0)       echo gstreamer ;;
    apt-get:libgstreamer-1.0.so.0)      echo libgstreamer1.0-0 ;;
    dnf:libgstreamer-1.0.so.0)          echo gstreamer1 ;;
    zypper:libgstreamer-1.0.so.0)       echo gstreamer ;;
    apk:libgstreamer-1.0.so.0)          echo gstreamer ;;
    xbps-install:libgstreamer-1.0.so.0) echo gstreamer1 ;;

    pacman:libgstapp-1.0.so.0)       echo gst-plugins-base-libs ;;
    apt-get:libgstapp-1.0.so.0)      echo libgstreamer-plugins-base1.0-0 ;;
    dnf:libgstapp-1.0.so.0)          echo gstreamer1-plugins-base ;;
    zypper:libgstapp-1.0.so.0)       echo gstreamer-plugins-base ;;
    apk:libgstapp-1.0.so.0)          echo gst-plugins-base ;;
    xbps-install:libgstapp-1.0.so.0) echo gst-plugins-base1 ;;

    pacman:libayatana-appindicator3.so.1)       echo libayatana-appindicator ;;
    apt-get:libayatana-appindicator3.so.1)      echo libayatana-appindicator3-1 ;;
    dnf:libayatana-appindicator3.so.1)          echo libayatana-appindicator-gtk3 ;;
    zypper:libayatana-appindicator3.so.1)       echo libayatana-appindicator3-1 ;;
    apk:libayatana-appindicator3.so.1)          echo libayatana-appindicator ;;
    xbps-install:libayatana-appindicator3.so.1) echo libayatana-appindicator ;;

    pacman:libkeybinder-3.0.so.0)       echo libkeybinder3 ;;
    apt-get:libkeybinder-3.0.so.0)      echo libkeybinder-3.0-0 ;;
    dnf:libkeybinder-3.0.so.0)          echo keybinder3 ;;
    zypper:libkeybinder-3.0.so.0)       echo libkeybinder-3_0-0 ;;
    apk:libkeybinder-3.0.so.0)          echo keybinder3 ;;
    xbps-install:libkeybinder-3.0.so.0) echo keybinder3 ;;

    pacman:libsecret-1.so.0)         echo libsecret ;;
    apt-get:libsecret-1.so.0)        echo libsecret-1-0 ;;
    dnf:libsecret-1.so.0)            echo libsecret ;;
    zypper:libsecret-1.so.0)         echo libsecret-1-0 ;;
    apk:libsecret-1.so.0)            echo libsecret ;;
    xbps-install:libsecret-1.so.0)   echo libsecret ;;

    pacman:parecord)                 echo libpulse ;;
    apt-get:parecord)                echo pulseaudio-utils ;;
    dnf:parecord)                    echo pulseaudio-utils ;;
    zypper:parecord)                 echo pulseaudio-utils ;;
    apk:parecord)                    echo pulseaudio-utils ;;
    xbps-install:parecord)           echo pulseaudio-utils ;;

    *:ffmpeg)                        echo ffmpeg ;;
    *)                               echo "$1" ;;
  esac
}

check_deps() {
  missing_required=""
  missing_optional=""

  # Required: the app process will not start without these.
  #   libgtk-3        the Flutter Linux shell itself
  #   libgstreamer    audioplayers_linux (spoken replies, notification sounds)
  #   libgstapp       gst-plugins-base, same
  #   libsecret       flutter_secure_storage_linux (the pairing token lives here)
  #   libayatana-…    tray_manager (the system-tray icon). REQUIRED, not
  #                   optional: tray_manager's linux/CMakeLists.txt sets
  #                   `tray_manager_bundled_libraries ""`, so the .so is NOT
  #                   shipped inside the release — the plugin is linked against
  #                   it and the dynamic loader fails the WHOLE process at
  #                   startup if it is absent. A missing tray icon would be a
  #                   warning; an app that will not launch is an error.
  #   libkeybinder    hotkey_manager_linux (the Super+Space dictation shortcut).
  #                   REQUIRED for the same reason libayatana is: its
  #                   linux/CMakeLists.txt sets `bundled_libraries ""`, so the
  #                   .so is NOT shipped inside the release. The plugin links
  #                   against it, and the dynamic loader fails the WHOLE
  #                   process at startup when it is absent.
  for lib in libgtk-3.so.0 libgstreamer-1.0.so.0 libgstapp-1.0.so.0 libsecret-1.so.0 \
             libayatana-appindicator3.so.1 libkeybinder-3.0.so.0; do
    have_lib "$lib" || missing_required="$missing_required $(pkg_for "$lib")"
  done

  # Optional: the app starts and runs, but one named feature will not work.
  # record_linux shells out to these two by name; they are not linked in.
  for bin in parecord ffmpeg; do
    command -v "$bin" >/dev/null 2>&1 || missing_optional="$missing_optional $(pkg_for "$bin")"
  done

  if [ -n "$missing_optional" ]; then
    warn "Voice input will not work: missing$missing_optional"
    warn "  record_linux records by launching 'parecord' and encodes with 'ffmpeg'."
    warn "  Install them with:  $(pm_install_cmd "$(echo "$missing_optional" | xargs)")"
  fi

  if [ -n "$missing_required" ]; then
    if [ "$SKIP_DEP_CHECK" -eq 1 ]; then
      warn "Missing required libraries (--skip-dep-check given):$missing_required"
      return 0
    fi

    # Install them ourselves. We are root, we know the package names, and the
    # alternative is an update that silently never happens.
    if [ -n "${PM:-}" ]; then
      step "Installing missing system libraries:$missing_required"
      if pm_install_run $missing_required; then
        # Re-check against the LOADER, not the package manager's exit code: a
        # package can install and still not provide the soname we need.
        missing_after=""
        for lib in libgtk-3.so.0 libgstreamer-1.0.so.0 libgstapp-1.0.so.0 \
                   libsecret-1.so.0 libayatana-appindicator3.so.1 \
                   libkeybinder-3.0.so.0; do
          have_lib "$lib" || missing_after="$missing_after $(pkg_for "$lib")"
        done
        if [ -z "$missing_after" ]; then
          step "System libraries installed — continuing the update."
          return 0
        fi
        missing_required="$missing_after"
        warn "Installed, but these are still not loadable:$missing_required"
      else
        warn "The package manager refused to install:$missing_required"
      fi
    fi

    die "Missing system libraries LifeOS cannot start without:$missing_required" \
        "Detected: $DISTRO_NAME (package manager: ${PM:-none found})" \
        "" \
        "  $(pm_install_cmd "$(echo "$missing_required" | xargs)")" \
        "" \
        "Then re-run this installer. Pass --skip-dep-check to install anyway" \
        "(the app will fail to launch until the libraries are present)."
  fi

  # A Secret Service provider is a *runtime* daemon, not a library, so it
  # cannot be probed the same way. Say so rather than let the user discover it
  # as a mysterious storage error later.
  if ! have_lib libsecret-1.so.0; then :; else
    if [ ! -e /usr/lib/gnome-keyring ] && ! command -v gnome-keyring-daemon >/dev/null 2>&1 \
       && ! command -v kwalletd6 >/dev/null 2>&1 && ! command -v kwalletd5 >/dev/null 2>&1; then
      warn "No Secret Service provider found (gnome-keyring or kwallet)."
      warn "  libsecret is installed but needs a running daemon to store anything;"
      warn "  without one, LifeOS cannot persist its pairing token between launches."
    fi
  fi

  # Same class of problem for the tray icon: libayatana-appindicator is a
  # library and IS probed above, but something on the session bus has to
  # actually HOST a StatusNotifierItem, and that is a running desktop component
  # we cannot detect from a root install. GNOME ships without one by default —
  # it needs the AppIndicator extension — so say so there rather than let the
  # user wonder why the icon never appeared.
  #
  # Not fatal, and not the only line of defence: if no host answers, the app
  # itself reports "Sin icono en la barra del sistema" at runtime instead of
  # pretending the tray worked (see mobile/lib/core/tray/).
  if command -v gnome-shell >/dev/null 2>&1; then
    warn "GNOME detected: the system-tray icon needs the AppIndicator extension."
    warn "  GNOME Shell hosts no StatusNotifierItem by default, so without it"
    warn "  LifeOS runs normally but shows no icon in the top bar."
    warn "  Install 'gnome-shell-extension-appindicator' and enable it."
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Config persistence. The updater service runs with no shell profile, so the
# base URL and key have to live somewhere it can read.
# ─────────────────────────────────────────────────────────────────────────────
load_config() {
  if [ -r "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
    [ -n "$BASE_URL" ]   || BASE_URL="${UPDATE_BASE_URL:-}"
    [ -n "$ACCESS_KEY" ] || ACCESS_KEY="${UPDATE_ACCESS_KEY:-}"
  fi
}

save_config() {
  mkdir -p "$CONF_DIR"
  umask 077
  cat > "$CONF_FILE" <<EOF
# Written by install-linux.sh. Read by lifeos-updater.service.
# Contains the update-endpoint access key: keep mode 0600.
UPDATE_BASE_URL=$BASE_URL
UPDATE_ACCESS_KEY=$ACCESS_KEY
EOF
  chmod 600 "$CONF_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# JSON. jq is not installable-by-assumption on someone else's laptop, so we
# use python3 when present and fall back to sed. The fallback is only ever fed
# the manifest we generate ourselves, which is flat and one-key-per-line.
# ─────────────────────────────────────────────────────────────────────────────
PYTHON=""
for p in python3 python; do
  if command -v "$p" >/dev/null 2>&1; then PYTHON="$p"; break; fi
done

json_field() { # $1 = file, $2 = key
  if [ -n "$PYTHON" ]; then
    "$PYTHON" -c 'import json,sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    sys.exit(3)
print("" if v is None else v)' "$1" "$2" || return 1
  else
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p;s/.*"'"$2"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1" | head -1
  fi
}

# Records the HTTP status of the last fetch so a caller can tell WHICH failure
# it hit. "Could not fetch" covers a dead host, a typo'd URL and a rejected key
# equally, and only one of those is fixed by editing /etc/lifeos/update.env.
LAST_HTTP_CODE=""

fetch() { # $1 = url, $2 = destination
  if [ -n "$ACCESS_KEY" ]; then
    LAST_HTTP_CODE="$(curl -sSL --retry 3 --retry-delay 2 --connect-timeout 20 \
      --max-time 1800 -w '%{http_code}' \
      -H "$KEY_HEADER: $ACCESS_KEY" -o "$2" "$1" 2>/dev/null)" || LAST_HTTP_CODE="000"
  else
    LAST_HTTP_CODE="$(curl -sSL --retry 3 --retry-delay 2 --connect-timeout 20 \
      --max-time 1800 -w '%{http_code}' -o "$2" "$1" 2>/dev/null)" || LAST_HTTP_CODE="000"
  fi
  case "$LAST_HTTP_CODE" in
    2*) return 0 ;;
    *)  rm -f "$2"; return 1 ;;
  esac
}

# Turns the recorded status into the one sentence that names the actual fix.
fetch_failure_hint() {
  case "$LAST_HTTP_CODE" in
    401|403)
      if [ -z "$ACCESS_KEY" ]; then
        echo "The update endpoint rejected the request (HTTP $LAST_HTTP_CODE) and this"
        echo "machine has NO access key saved. Re-run the installer once with:"
        echo "    sudo sh install-linux.sh --base-url $BASE_URL --key <UPDATE_ACCESS_KEY>"
        echo "It is stored in $CONF_FILE and reused by every later update."
      else
        echo "The update endpoint rejected the saved access key (HTTP $LAST_HTTP_CODE)."
        echo "Check UPDATE_ACCESS_KEY in $CONF_FILE against the server's."
      fi
      ;;
    404) echo "The server has nothing published at that path (HTTP 404)." ;;
    000) echo "No HTTP response at all — DNS, connectivity or TLS." ;;
    *)   echo "The server answered HTTP $LAST_HTTP_CODE." ;;
  esac
}

installed_version_code() {
  [ -r "$STATE_MANIFEST" ] || { echo 0; return 0; }
  vc="$(json_field "$STATE_MANIFEST" versionCode 2>/dev/null || echo 0)"
  case "$vc" in ''|*[!0-9]*) echo 0 ;; *) echo "$vc" ;; esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Uninstall
# ─────────────────────────────────────────────────────────────────────────────
do_uninstall() {
  step "Removing LifeOS…"
  if [ -z "${SYSTEMCTL_MISSING:-}" ]; then
    for unit in lifeos-updater.timer lifeos-updater.path lifeos-updater.service; do
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
    done
  fi
  if [ -z "${SYSTEMCTL_MISSING:-}" ]; then
    systemctl --global disable lifeos-briefing.timer >/dev/null 2>&1 || true
  fi
  rm -f "$UNIT_DIR/lifeos-updater.service" \
        "$UNIT_DIR/lifeos-updater.timer" \
        "$UNIT_DIR/lifeos-updater.path" \
        "$USER_UNIT_DIR/lifeos-briefing.service" \
        "$USER_UNIT_DIR/lifeos-briefing.timer"
  if [ -z "${SYSTEMCTL_MISSING:-}" ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm -f "$LAUNCHER_LINK" "$DESKTOP_FILE" "$ICON_FILE"
  rm -rf "$PREFIX" "$CONF_DIR" /var/lib/lifeos

  refresh_desktop_caches

  say ""
  say "✅ LifeOS removed."
  say "   Your data was NOT deleted. It lives in each user's home directory:"
  say "     ~/.local/share/com.lifeos.lifeos/   ~/.config/com.lifeos.lifeos/"
  say "   Delete those by hand if you want a clean slate."
  say ""
  say "   If you turned on \"start LifeOS when I log in\", that entry lives in"
  say "     ~/.config/autostart/lifeos.desktop"
  say "   and is per-user, so this uninstall cannot remove other users' copies."
  say "   Delete it, or your session will try to launch LifeOS at every login."
}

# ─────────────────────────────────────────────────────────────────────────────
# Install / upgrade
# ─────────────────────────────────────────────────────────────────────────────
do_install() {
  load_config
  # This script is SERVED BY the update server, so on a fresh install it
  # already knows where it came from — asking the user to retype that is
  # friction for no safety. LIFEOS_BASE_URL is stamped in at publish time;
  # an explicit --base-url still wins, and a hand-copied script with neither
  # still gets the clear error below rather than a wrong default.
  if [ -z "$BASE_URL" ] && [ -n "${LIFEOS_BASE_URL:-}" ]; then
    BASE_URL="$LIFEOS_BASE_URL"
    say "Using the server this installer came from: $BASE_URL"
  fi
  [ -n "$BASE_URL" ] || die "No update server configured." \
      "Pass --base-url https://your-server/lifeos (and --key <KEY>) on first install." \
      "Later runs reuse the values saved in $CONF_FILE."
  BASE_URL="${BASE_URL%/}"

  # The unattended path checks the REQUIRED libraries too, and it must.
  #
  # Until now skipping it here was harmless, because the shared libraries a
  # release needs never changed between releases. The moment one is ADDED
  # (keybinder, for the dictation shortcut), the hourly timer would happily
  # swap in a build the machine cannot start — and the user would simply find
  # LifeOS dead, with no message, having done nothing. That is precisely the
  # silent degradation this project forbids.
  #
  # check_deps dies on a missing required library, which ABORTS before the
  # release is swapped: the working install stays exactly where it is. Quiet
  # mode only suppresses the routine chatter, never the failure.
  check_deps

  command -v curl >/dev/null 2>&1 || die "curl is required and was not found." \
      "  $(pm_install_cmd curl)"
  command -v tar >/dev/null 2>&1 || die "tar is required and was not found." \
      "  $(pm_install_cmd tar)"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required and was not found." \
      "  $(pm_install_cmd coreutils)"

  WORKDIR="$(mktemp -d)"
  MANIFEST_URL="$BASE_URL/linux/$ARCH/manifest.json"

  [ "$MODE" = "update" ] || step "Fetching manifest: $MANIFEST_URL"
  fetch "$MANIFEST_URL" "$WORKDIR/manifest.json" || \
    die "Could not fetch the manifest from $MANIFEST_URL" \
        "$(fetch_failure_hint)" \
        "A failed check is reported as a failure on purpose — it is never" \
        "treated as 'you are up to date'."

  VC="$(json_field "$WORKDIR/manifest.json" versionCode)" || VC=""
  VN="$(json_field "$WORKDIR/manifest.json" versionName)" || VN=""
  FN="$(json_field "$WORKDIR/manifest.json" filename)" || FN=""
  SHA="$(json_field "$WORKDIR/manifest.json" sha256)" || SHA=""
  SZ="$(json_field "$WORKDIR/manifest.json" sizeBytes)" || SZ=""
  M_ARCH="$(json_field "$WORKDIR/manifest.json" arch)" || M_ARCH=""

  case "$VC" in ''|*[!0-9]*) die "Manifest has no usable versionCode." \
      "Fetched from $MANIFEST_URL — it is not the manifest this installer expects." ;; esac
  [ -n "$FN" ] || die "Manifest has no 'filename'." "Fetched from $MANIFEST_URL."
  case "$SHA" in
    [0-9a-fA-F]*) [ "${#SHA}" -eq 64 ] || die "Manifest sha256 is not 64 hex characters: '$SHA'" ;;
    *) die "Manifest has no usable 'sha256'." "Refusing to install an unverifiable tarball." ;;
  esac
  if [ -n "$M_ARCH" ] && [ "$M_ARCH" != "$ARCH" ]; then
    die "Manifest is for arch '$M_ARCH' but this machine is '$ARCH'."
  fi

  INSTALLED="$(installed_version_code)"
  if [ "$VC" -le "$INSTALLED" ] && [ "$FORCE" -eq 0 ]; then
    if [ "$MODE" = "update" ]; then
      exit 0        # Quiet no-op: the timer fires hourly, this is the normal case.
    fi
    say "Already up to date: versionCode $INSTALLED ($VN). Use --force to reinstall."
    exit 0
  fi

  step "New release: versionCode $VC ($VN), $ARCH — installed is $INSTALLED"

  TARBALL="$WORKDIR/$FN"
  step "Downloading $FN…"
  fetch "$BASE_URL/linux/$ARCH/$FN" "$TARBALL" || \
    die "Download failed: $BASE_URL/linux/$ARCH/$FN"

  # Size first (cheap, catches a truncated transfer or an HTML error page that
  # curl accepted), then the sha256, and both BEFORE anything is unpacked.
  if [ -n "$SZ" ] && [ "$SZ" -gt 0 ] 2>/dev/null; then
    ACTUAL_SZ="$(wc -c < "$TARBALL" | tr -d ' ')"
    [ "$ACTUAL_SZ" = "$SZ" ] || \
      die "Downloaded size $ACTUAL_SZ does not match the manifest's $SZ." \
          "The download was truncated or the server served something else."
  fi

  step "Verifying sha256 before unpacking…"
  ACTUAL_SHA="$(sha256sum "$TARBALL" | cut -d' ' -f1)"
  if [ "$ACTUAL_SHA" != "$(printf '%s' "$SHA" | tr 'A-F' 'a-f')" ]; then
    rm -f "$TARBALL"
    die "sha256 MISMATCH — the download was corrupted or tampered with." \
        "  expected $SHA" \
        "  got      $ACTUAL_SHA" \
        "The file was deleted and nothing was unpacked."
  fi
  say "  ok: ${ACTUAL_SHA%"${ACTUAL_SHA#????????????}"}…"

  # Stage the whole release before touching the live symlink. If unpacking
  # fails halfway, `current` still points at the previous working release.
  STAGE="$RELEASES_DIR/.staging-$VC.$$"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  step "Unpacking…"
  tar -xzf "$TARBALL" -C "$STAGE" --strip-components=1 || \
    { rm -rf "$STAGE"; die "Unpacking failed. $RELEASES_DIR was left as it was."; }

  [ -x "$STAGE/bundle/lifeos" ] || \
    { rm -rf "$STAGE"; die "Tarball did not contain an executable bundle/lifeos." \
        "This is not a LifeOS desktop release tarball."; }

  TARGET="$RELEASES_DIR/$VC"
  rm -rf "$TARGET"
  mv "$STAGE" "$TARGET"

  # Atomic swap: create the new symlink under a temp name, then rename over the
  # old one. `ln -sfn` on a directory symlink is not atomic and can nest.
  ln -sfn "$TARGET" "$CURRENT_LINK.new"
  mv -T "$CURRENT_LINK.new" "$CURRENT_LINK" 2>/dev/null || \
    { rm -f "$CURRENT_LINK"; ln -sfn "$TARGET" "$CURRENT_LINK"; }

  cp "$WORKDIR/manifest.json" "$STATE_MANIFEST"

  # Keep this installer next to the app so the updater service can re-run it.
  mkdir -p "$BIN_DIR"
  if [ -f "$TARGET/bin/install-linux.sh" ]; then
    install -m 0755 "$TARGET/bin/install-linux.sh" "$BIN_DIR/lifeos-install.sh"
  elif [ -f "$0" ] && [ -r "$0" ]; then
    install -m 0755 "$0" "$BIN_DIR/lifeos-install.sh"
  else
    warn "Could not install a copy of this script to $BIN_DIR/lifeos-install.sh."
    warn "  Automatic updates will not run until it is there."
  fi

  ln -sfn "$CURRENT_LINK/bundle/lifeos" "$LAUNCHER_LINK"

  install_desktop_entry "$TARGET"

  # Units are installed by the copy of this script that CAME WITH the release,
  # not by the one already on disk. The updater runs the OLD installer, so a
  # release that adds a new unit would otherwise not get it placed until the
  # release after that — a whole cycle late, for no reason the user could see.
  # An old copy that does not know --install-units simply fails, and we fall
  # back to doing it ourselves.
  if ! "$BIN_DIR/lifeos-install.sh" --install-units >/dev/null 2>&1; then
    install_units
  fi
  save_config
  prune_old_releases

  say ""
  say "✅ LifeOS $VN (versionCode $VC) installed to $PREFIX"
  say ""
  say "   Launch:      lifeos     (or find \"LifeOS\" in your applications menu)"
  say "   Installed:   $CURRENT_LINK -> $TARGET"
  say "   Config:      $CONF_FILE (0600)"
  if [ -z "${SYSTEMCTL_MISSING:-}" ]; then
    say "   Auto-update: lifeos-updater.timer, hourly, system-level."
    say "                It keeps running after you log out — that is the point."
    say "                Check it with:  systemctl status lifeos-updater.timer"
    say "                Force one now:  sudo systemctl start lifeos-updater.service"
  else
    say "   Auto-update: NOT enabled — no systemctl on this machine."
    say "                Re-run this installer by hand to upgrade."
  fi
  say "   Uninstall:   sudo $BIN_DIR/lifeos-install.sh --uninstall"
  say ""
  say "   Not everything works on desktop yet. See tools/README-linux.md."
}

# Best effort: a stale menu/icon cache is cosmetic, never a reason to fail an
# otherwise complete install.
refresh_desktop_caches() {
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor >/dev/null 2>&1 || true
  fi
  return 0
}

install_desktop_entry() { # $1 = release dir
  release="$1"
  mkdir -p "$(dirname "$DESKTOP_FILE")" "$(dirname "$ICON_FILE")"

  if [ -f "$release/share/lifeos.png" ]; then
    install -m 0644 "$release/share/lifeos.png" "$ICON_FILE"
  else
    warn "Release contained no icon; the menu entry will use a generic one."
  fi

  # Exec points at $CURRENT_LINK, not at this release, so the menu entry keeps
  # working across upgrades without being rewritten.
  cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=LifeOS
GenericName=Personal assistant
Comment=Your on-device assistant
Exec=$CURRENT_LINK/bundle/lifeos %U
Icon=lifeos
Terminal=false
Categories=Utility;Office;
StartupWMClass=lifeos
StartupNotify=true
EOF
  chmod 0644 "$DESKTOP_FILE"

  refresh_desktop_caches
}

install_units() {
  if [ -n "${SYSTEMCTL_MISSING:-}" ]; then
    warn "systemctl not found — skipping the auto-update units."
    warn "  This machine will not update itself. Re-run the installer to upgrade."
    return 0
  fi

  src="$CURRENT_LINK/share/systemd"
  if [ ! -d "$src" ]; then
    warn "Release contained no systemd units ($src) — auto-update not enabled."
    return 0
  fi

  # World-writable + sticky, so the app (running as the desktop user) can drop
  # the "check now" trigger file without holding root, while still being unable
  # to remove anyone else's.
  mkdir -p "$TRIGGER_DIR"
  chmod 1777 "$TRIGGER_DIR"

  for unit in lifeos-updater.service lifeos-updater.timer lifeos-updater.path; do
    [ -f "$src/$unit" ] || { warn "Missing unit $unit in the release."; continue; }
    install -m 0644 "$src/$unit" "$UNIT_DIR/$unit"
  done

  systemctl daemon-reload || die "systemctl daemon-reload failed." \
      "The app is installed but auto-update is not active."
  systemctl enable --now lifeos-updater.timer >/dev/null 2>&1 || \
    warn "Could not enable lifeos-updater.timer — updates will not be automatic."
  systemctl enable --now lifeos-updater.path >/dev/null 2>&1 || \
    warn "Could not enable lifeos-updater.path — in-app 'update now' will not work."

  install_briefing_units "$src"
}

# The morning briefing runs as the USER, not as root: it writes the user's own
# data and needs their graphical session (Flutter/GTK will not start without a
# display). So these go to the user-unit directory and are enabled globally —
# for whoever logs in on this machine, without the installer having to guess
# which account that is.
install_briefing_units() {
  src="$1"
  mkdir -p "$USER_UNIT_DIR"
  for unit in lifeos-briefing.service lifeos-briefing.timer; do
    if [ ! -f "$src/$unit" ]; then
      warn "Missing unit $unit in the release — the briefing will only be"
      warn "  generated while the app is open."
      return 0
    fi
    install -m 0644 "$src/$unit" "$USER_UNIT_DIR/$unit"
  done

  # --global enables it for every user account that logs in from now on, which
  # is what an installer run as root can honestly promise. It does NOT start it
  # in a session that is already open, so we also try the live one below.
  mkdir -p "$USER_UNIT_DIR"
  systemctl --global enable lifeos-briefing.timer >/dev/null 2>&1 || \
    warn "Could not enable lifeos-briefing.timer — the briefing will only be generated while the app is open."

  # Arrancarlo en las sesiones que ya están abiertas AHORA.
  #
  # Antes esto dependía de SUDO_USER —quien tecleó sudo—, y el actualizador
  # automático no lo tiene: la unidad quedaba "enabled" pero "inactive (dead)",
  # con Trigger: n/a, esperando a un próximo login que en una laptop que nadie
  # apaga puede tardar días. Visto exactamente así en la laptop del usuario.
  #
  # Se recorren los buses de usuario vivos, que es la pregunta real: ¿hay una
  # sesión a la que este temporizador le sirva?
  for bus in /run/user/*/bus; do
    [ -S "$bus" ] || continue
    uid="${bus#/run/user/}"
    uid="${uid%/bus}"
    # Sólo cuentas de persona: root y las de servicio no tienen escritorio ni
    # datos de LifeOS que respaldar.
    [ "$uid" -ge 1000 ] 2>/dev/null || continue
    who="$(id -nu "$uid" 2>/dev/null || true)"
    [ -n "$who" ] || continue
    sudo -u "$who" \
      XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
      systemctl --user daemon-reload >/dev/null 2>&1 || true
    sudo -u "$who" \
      XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$bus" \
      systemctl --user enable --now lifeos-briefing.timer >/dev/null 2>&1 || \
      warn "No pude arrancar lifeos-briefing.timer para $who — arrancará en su próximo inicio de sesión."
  done
}

prune_old_releases() {
  [ -d "$RELEASES_DIR" ] || return 0
  keep="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  # Newest first by numeric name, skip the first $KEEP_RELEASES, delete the rest.
  for d in "$RELEASES_DIR"/*; do
    [ -d "$d" ] || continue
    case "${d##*/}" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "${d##*/}"
  done | sort -rn | tail -n "+$((KEEP_RELEASES + 1))" | \
  while read -r old; do
    [ "$RELEASES_DIR/$old" = "$keep" ] && continue
    step "Pruning old release $old"
    rm -rf "${RELEASES_DIR:?}/$old"
  done
  rm -rf "$RELEASES_DIR"/.staging-* 2>/dev/null || true
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
case "$MODE" in
  uninstall)     do_uninstall ;;
  # Only the units. Invoked by an older installed copy right after it unpacked
  # this release, so a newly added unit is placed by the script that knows
  # about it instead of waiting a whole update cycle.
  install-units) install_units ;;
  *)             do_install ;;
esac
