#!/usr/bin/env bash
# Writing into the OTA store, which is now a Coolify-managed Docker volume.
#
# WHY THIS FILE EXISTS. The update artifacts used to sit in a plain host
# directory (`~/lifeos-updates`) that the nginx container bind-mounted. That put
# 23 GB of releases outside anything Coolify knew about: no backup, no
# versioning, and gone with the host. They now live in the named volume
# `l8sw4ookgck4cgw8kwwg8s4w_lifeos-ota-artifacts`, which Coolify created,
# declares in the service's compose, and can back up.
#
# A named volume has no stable host path a script may write to — and reaching
# into /var/lib/docker/volumes/… would recreate exactly the "loose on the host"
# habit we just removed. So every write goes through a throwaway container that
# mounts the volume, writes, and exits.
#
# THE WEB SERVER STAYS READ-ONLY. nginx mounts the volume `:ro`. That is not
# incidental: the process exposed to the internet has no way to modify what it
# serves. Publishing is a separate, short-lived container with write access.
#
# EVERY WRITE IS ATOMIC. Content lands on a `.part` file and is renamed into
# place. A publish interrupted halfway leaves the previous release intact rather
# than a truncated tarball advertised by a manifest that already moved.

set -euo pipefail

# The volume Coolify created for the service. Coolify prefixes the compose key
# with the service UUID, so this is NOT simply "lifeos-ota-artifacts" — a fact
# that cost one outage to learn, when a pre-created volume under the unprefixed
# name was silently ignored and the service came up serving an empty directory.
: "${OTA_VOLUME:=l8sw4ookgck4cgw8kwwg8s4w_lifeos-ota-artifacts}"

# Image used for the throwaway writer. Pinned to a digest-less tag on purpose:
# it only ever runs `cat`, `mkdir`, `chmod` and `mv`.
: "${OTA_WRITER_IMAGE:=alpine:latest}"

# Quiet probe: is the OTA store reachable from THIS machine? True on the VPS,
# false on a laptop publishing over ssh. Used to choose the publish route, so
# it must not print or exit.
ota_volume_present() {
  command -v docker >/dev/null 2>&1 || return 1
  docker volume inspect "$OTA_VOLUME" >/dev/null 2>&1
}

ota_require_volume() {
  command -v docker >/dev/null 2>&1 || {
    echo "✗ docker no está disponible: no se puede publicar en el volumen OTA." >&2
    echo "  El almacén de actualizaciones vive en el volumen '$OTA_VOLUME'." >&2
    return 1
  }
  docker volume inspect "$OTA_VOLUME" >/dev/null 2>&1 || {
    echo "✗ No existe el volumen OTA '$OTA_VOLUME'." >&2
    echo "  Lo crea Coolify al desplegar el servicio lifeos-ota." >&2
    echo "  Publicar sin él dejaría los artefactos donde nadie los sirve." >&2
    return 1
  }
}

# ota_put <archivo-local> <ruta-dentro-del-volumen> [modo]
#
# Modo por defecto 0644 y NO el del archivo de origen: los manifiestos se
# generan con mktemp (0600), nginx corre como otro usuario, y copiar el modo
# fielmente ya produjo una vez un manifiesto que daba 403 mientras el tarball
# se servía bien — lo que se lee como un bug de ruteo y no lo es.
ota_put() {
  local src="$1" dest="$2" mode="${3:-0644}"
  [ -f "$src" ] || { echo "✗ No existe el archivo a publicar: $src" >&2; return 1; }
  docker run --rm -i -v "$OTA_VOLUME:/srv" "$OTA_WRITER_IMAGE" sh -c "
    set -e
    dir=\$(dirname '/srv/$dest')
    mkdir -p \"\$dir\"
    cat > '/srv/$dest.part'
    chmod $mode '/srv/$dest.part'
    mv '/srv/$dest.part' '/srv/$dest'
  " < "$src"
}

# ota_link <destino> <nombre-del-enlace>  (ambos relativos a la raíz del volumen)
ota_link() {
  local target="$1" link="$2"
  docker run --rm -v "$OTA_VOLUME:/srv" "$OTA_WRITER_IMAGE" sh -c "
    set -e
    cd \"\$(dirname '/srv/$link')\"
    ln -sfn '$target' \"\$(basename '$link')\"
  "
}

# ota_ls <ruta-relativa> — para verificar desde el script que publica.
ota_ls() {
  docker run --rm -v "$OTA_VOLUME:/srv:ro" "$OTA_WRITER_IMAGE" \
    sh -c "ls -l '/srv/${1:-}'"
}

# ota_prune <dir-relativo> <sufijo> <cuántos-conservar> [--dry-run]
#
# Old releases accumulate forever otherwise: 65 APKs at ~318 MB had reached
# 16.4 GB — most of the update store, and none of it reachable by any client,
# because the app only ever downloads what the manifest advertises.
#
# NEVER DELETED, regardless of the count:
#   * the file the manifest currently advertises
#   * the target of any symlink in the directory (current.apk)
# A retention policy that can delete the live release is not a retention
# policy, it is an outage on a timer.
#
# Ordering is by the versionCode parsed from the filename, NOT by mtime: a
# re-published build gets a fresh mtime and would otherwise look newer than the
# releases that actually supersede it.
#
# The body is piped into the container as a script rather than embedded in a
# quoted `sh -c` string. Nesting shell quoting three levels deep is how you get
# a deletion loop that silently matches the wrong files.
ota_prune() {
  local dir="$1" suffix="$2" keep="$3" dry="${4:-}"
  docker run --rm -i -v "$OTA_VOLUME:/srv" "$OTA_WRITER_IMAGE" \
    sh -s -- "$dir" "$suffix" "$keep" "$dry" <<'PRUNE'
set -eu
dir=$1; suffix=$2; keep=$3; dry=${4:-}

cd "/srv/$dir" 2>/dev/null || exit 0

# Everything that must survive, one name per line.
{
  for m in manifest.json */manifest.json; do
    [ -f "$m" ] || continue
    sed -n 's/.*"filename"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$m"
  done
  for l in * ; do
    [ -L "$l" ] || continue
    readlink "$l"
  done
} 2>/dev/null | sort -u > /tmp/protected

for f in *"$suffix"; do
  [ -f "$f" ] || continue
  # versionCode = trailing digits before the suffix
  code=$(printf '%s' "$f" | sed -n "s/.*-\([0-9][0-9]*\)$(printf '%s' "$suffix" | sed 's/\./\\./g')\$/\1/p")
  [ -n "$code" ] || continue
  printf '%s %s\n' "$code" "$f"
done | sort -rn -k1,1 | tail -n +$((keep + 1)) | cut -d' ' -f2- | while read -r f; do
  if grep -qxF "$f" /tmp/protected; then
    echo "  conservado (en uso): $f"
    continue
  fi
  size=$(du -h "$f" | cut -f1)
  if [ -n "$dry" ]; then
    echo "  se borraría: $f ($size)"
  else
    rm -f "$f" && echo "  borrado: $f ($size)"
  fi
done
PRUNE
}
