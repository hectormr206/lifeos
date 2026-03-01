#!/bin/bash
#===============================================================================
# LifeOS Build ISO - Reconstruye imagen y genera ISO desde cero
#===============================================================================
# Ejecuta los pasos 0-3 del doc "Reconstruir imagen y generar ISO.md"
#
# Uso:
#   sudo ./scripts/build-iso.sh
#
# Desde Windows (WSL2):
#   wsl -d Ubuntu -- sudo bash /ruta/al/proyecto/scripts/build-iso.sh
#===============================================================================

set -euo pipefail

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "${BLUE}[LifeOS]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Detectar directorio del proyecto ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME="localhost/lifeos:latest"
OUTPUT_DIR="${LIFEOS_OUTPUT_DIR:-${PROJECT_ROOT}/output}"

# --- Validar que estamos en el directorio correcto ---
if [[ ! -f "$PROJECT_ROOT/image/Containerfile" ]]; then
    error "No se encontró image/Containerfile. Ejecuta desde la raíz del proyecto."
fi

# --- Validar root ---
if [[ $EUID -ne 0 ]]; then
    error "Este script necesita sudo. Ejecuta: sudo ./scripts/build-iso.sh"
fi

# --- Banner ---
echo -e "${CYAN}${BOLD}"
cat << 'BANNER'
   __    _ ____     ____  _____
  / /   (_) __/__  / __ \/ ___/
 / /   / / /_/ _ \/ / / /\__ \
/ /___/ / __/  __/ /_/ /___/ /
\____/_/_/  \___/\____//____/

  Build ISO - Full Pipeline
BANNER
echo -e "${NC}"

START_TIME=$(date +%s)

# ============================================
# Paso 0: Limpiar imagen anterior
# ============================================
log "Paso 0/3: Limpiando imagen anterior..."
if podman image exists "$IMAGE_NAME" 2>/dev/null; then
    podman rmi -f "$IMAGE_NAME" 2>/dev/null || true
    success "Imagen anterior eliminada"
else
    success "No hay imagen anterior que limpiar"
fi
echo

# ============================================
# Paso 1: Reconstruir imagen desde cero
# ============================================
log "Paso 1/3: Reconstruyendo imagen (esto puede tomar 15-30 min)..."
echo

podman build \
    --no-cache \
    -t "$IMAGE_NAME" \
    -f "$PROJECT_ROOT/image/Containerfile" \
    "$PROJECT_ROOT"

echo
success "Imagen construida: $IMAGE_NAME"
echo

# ============================================
# Paso 2: Verificar imagen
# ============================================
log "Paso 2/3: Verificando imagen..."

# Verificar ID=fedora en os-release
OS_ID=$(podman run --rm "$IMAGE_NAME" grep '^ID=' /usr/lib/os-release 2>/dev/null || echo "")
if echo "$OS_ID" | grep -q 'ID=fedora'; then
    success "os-release: $OS_ID"
else
    error "os-release no contiene ID=fedora (got: $OS_ID). bootc-image-builder fallará."
fi

# Verificar VARIANT_ID=lifeos
VARIANT=$(podman run --rm "$IMAGE_NAME" grep '^VARIANT_ID=' /usr/lib/os-release 2>/dev/null || echo "")
if echo "$VARIANT" | grep -q 'VARIANT_ID=lifeos'; then
    success "os-release: $VARIANT"
else
    warn "VARIANT_ID no es lifeos (got: $VARIANT)"
fi

# Verificar llama-server
LLAMA_PATH=$(podman run --rm "$IMAGE_NAME" which llama-server 2>/dev/null || echo "")
if [[ "$LLAMA_PATH" == "/usr/bin/llama-server" ]]; then
    success "llama-server: $LLAMA_PATH"
elif [[ -n "$LLAMA_PATH" ]]; then
    warn "llama-server en $LLAMA_PATH (esperado: /usr/bin/llama-server)"
else
    error "llama-server no encontrado en la imagen"
fi

# Verificar modelo pre-instalado
MODEL_CHECK=$(podman run --rm "$IMAGE_NAME" ls -lh /var/lib/lifeos/models/ 2>/dev/null || echo "")
if echo "$MODEL_CHECK" | grep -q '.gguf'; then
    success "Modelo AI pre-instalado"
else
    warn "No se encontró modelo .gguf pre-instalado"
fi

# Verificar life CLI
LIFE_VER=$(podman run --rm "$IMAGE_NAME" life --version 2>/dev/null || echo "")
if [[ -n "$LIFE_VER" ]]; then
    success "CLI: $LIFE_VER"
else
    error "life CLI no funciona en la imagen"
fi

echo

# ============================================
# Paso 3: Generar ISO
# ============================================
log "Paso 3/3: Generando ISO..."
echo

chmod +x "$PROJECT_ROOT/scripts/generate-iso-simple.sh"
bash "$PROJECT_ROOT/scripts/generate-iso-simple.sh" --type iso --image "$IMAGE_NAME"

echo

# --- Localizar ISO generado ---
ISO_FILE=$(find "$OUTPUT_DIR" -name "lifeos-*.iso" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

if [[ -z "$ISO_FILE" ]]; then
    error "No se encontró el ISO generado en $OUTPUT_DIR"
fi

ISO_SIZE=$(du -h "$ISO_FILE" | cut -f1)

# --- Resumen ---
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
MINUTES=$(( ELAPSED / 60 ))
SECONDS=$(( ELAPSED % 60 ))

echo
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  LifeOS ISO listo!${NC}"
echo -e "${GREEN}${BOLD}================================================================${NC}"
echo
echo -e "  ${BOLD}ISO:${NC}      $ISO_FILE"
echo -e "  ${BOLD}Tamaño:${NC}   $ISO_SIZE"
echo -e "  ${BOLD}Tiempo:${NC}   ${MINUTES}m ${SECONDS}s"
echo
echo -e "  ${BOLD}Siguiente paso:${NC}"
echo -e "  1. Crear VM en VirtualBox (Fedora 64-bit, 4GB RAM, 40GB disco, EFI)"
echo -e "  2. Montar el ISO como unidad óptica"
echo -e "  3. Instalar (usuario: ${CYAN}lifeos${NC} / password: ${CYAN}lifeos${NC})"
echo -e "  4. Después de instalar, verificar con: ${CYAN}sudo life check${NC}"
echo
