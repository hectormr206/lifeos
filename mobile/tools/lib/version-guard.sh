# shellcheck shell=bash
#
# Que la versión que lee un humano no se quede congelada.
#
# El versionCode sube solo (es el número de commits), así que el OTA siempre
# funciona aunque nadie toque el `version:` de pubspec.yaml — y por eso mismo
# nadie se entera de que lleva días sin moverse. Pasó: entre el 2026-08-20 y el
# 2026-08-24 se publicaron dieciséis compilaciones, con tres funciones nuevas
# dentro, todas etiquetadas 0.13.0.
#
# Este guardarraíl convierte ese olvido en una decisión: si la versión que vas a
# publicar ya está publicada, aborta y te enseña qué ha cambiado desde entonces.
# Publicar la misma sigue siendo legítimo (una corrección de última hora sobre
# una versión recién sacada), pero hay que pedirlo: LIFEOS_MISMA_VERSION=1.

lifeos_guard_version() {
  local version_name="$1" manifest_url="$2" key_header="$3" key="$4" repo_root="$5"

  if [[ "${LIFEOS_MISMA_VERSION:-0}" == "1" ]]; then
    echo "→ Publicando otra vez la $version_name (LIFEOS_MISMA_VERSION=1)."
    return 0
  fi

  local live
  live="$(curl -fsS --max-time 25 -H "$key_header: $key" "$manifest_url" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("versionName",""))' 2>/dev/null || true)"

  # Sin respuesta no se puede comparar. NO se inventa un permiso: se dice y se
  # sigue, porque bloquear una publicación por un fallo de red sería peor.
  if [[ -z "$live" ]]; then
    echo "⚠️  No pude leer la versión publicada en $manifest_url — sigo sin comprobarla." >&2
    return 0
  fi

  if [[ "$live" != "$version_name" ]]; then
    echo "→ Versión: $version_name (la publicada es la $live)."
    return 0
  fi

  echo "" >&2
  echo "⛔ La $version_name YA está publicada en este canal." >&2
  echo "" >&2
  local range_start
  range_start="$(git -C "$repo_root" log -S"version: $version_name" \
    --format='%H' -- mobile/pubspec.yaml 2>/dev/null | head -1)"
  if [[ -n "$range_start" ]]; then
    local total feats
    total="$(git -C "$repo_root" rev-list --count "$range_start..HEAD" 2>/dev/null || echo '?')"
    feats="$(git -C "$repo_root" log --format='%s' "$range_start..HEAD" 2>/dev/null | grep -cE '^feat' || true)"
    echo "   Desde que se puso la $version_name: $total commits, $feats con funciones nuevas." >&2
    git -C "$repo_root" log --format='     · %s' "$range_start..HEAD" 2>/dev/null | head -8 >&2
    echo "" >&2
  fi
  echo "   Sube 'version:' en mobile/pubspec.yaml y vuelve a lanzarlo." >&2
  echo "   Si de verdad quieres republicar la misma: LIFEOS_MISMA_VERSION=1 $0 ..." >&2
  echo "" >&2
  return 1
}
