#!/bin/bash
#===============================================================================
# LifeOS ISO Generator - Versión Simplificada
#===============================================================================
# Genera un ISO/VMDK booteable de LifeOS usando podman + bootc-image-builder.
#
# Uso:
#   ./scripts/generate-iso-simple.sh              # Genera ISO (default)
#   ./scripts/generate-iso-simple.sh --type vmdk  # Genera VMDK para VirtualBox
#   ./scripts/generate-iso-simple.sh --type qcow2 # Genera QCOW2 para QEMU/KVM
#
# Requisitos:
#   - Podman instalado (sudo apt install podman  o  sudo dnf install podman)
#   - Ejecutar como root o con sudo (bootc-image-builder requiere --privileged)
#
# Desde Windows (WSL2):
#   wsl -d Ubuntu -- sudo bash /ruta/al/proyecto/scripts/generate-iso-simple.sh
#===============================================================================

set -euo pipefail

# --- Configuración ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${PROJECT_ROOT}/output"
IMAGE_NAME="localhost/lifeos:latest"
BUILD_TYPE="${1:-iso}"
BIB_IMAGE="quay.io/centos-bootc/bootc-image-builder:latest"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${BLUE}[LifeOS]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Parsear argumentos ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --type|-t)  BUILD_TYPE="$2"; shift 2 ;;
        --image|-i) IMAGE_NAME="$2"; shift 2 ;;
        --help|-h)
            echo "Uso: $0 [--type iso|vmdk|qcow2|raw] [--image IMAGE]"
            echo ""
            echo "Opciones:"
            echo "  --type TYPE    Formato de salida: iso (default), vmdk, qcow2, raw"
            echo "  --image IMAGE  Imagen OCI a usar (default: localhost/lifeos:latest)"
            exit 0
            ;;
        *) shift ;;
    esac
done

# --- Banner ---
echo -e "${CYAN}"
cat << 'BANNER'
   __    _ ____     ____  _____
  / /   (_) __/__  / __ \/ ___/
 / /   / / /_/ _ \/ / / /\__ \
/ /___/ / __/  __/ /_/ /___/ /
\____/_/_/  \___/\____//____/

  ISO Generator v0.1
BANNER
echo -e "${NC}"

# --- Verificar prerequisitos ---
log "Verificando prerequisitos..."

if ! command -v podman &>/dev/null; then
    error "Podman no está instalado. Instálalo con: sudo apt install podman (Ubuntu) o sudo dnf install podman (Fedora)"
fi

if [[ $EUID -ne 0 ]]; then
    error "Este script necesita ejecutarse como root. Usa: sudo $0"
fi

# Verificar que BUILD_TYPE es válido
case "$BUILD_TYPE" in
    iso|vmdk|qcow2|raw) ;;
    *) error "Tipo de build inválido: $BUILD_TYPE. Usa: iso, vmdk, qcow2 o raw" ;;
esac

success "Prerequisitos OK"

# --- Paso 1: Construir la imagen si no existe ---
log "Verificando imagen del contenedor..."

if ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
    log "Imagen '$IMAGE_NAME' no encontrada. Construyendo..."
    log "Esto puede tomar 15-30 minutos la primera vez..."
    echo ""

    if [[ ! -f "$PROJECT_ROOT/image/Containerfile" ]]; then
        error "No se encontró $PROJECT_ROOT/image/Containerfile"
    fi

    podman build \
        -t "$IMAGE_NAME" \
        -f "$PROJECT_ROOT/image/Containerfile" \
        "$PROJECT_ROOT"

    success "Imagen construida: $IMAGE_NAME"
else
    success "Imagen encontrada: $IMAGE_NAME"
fi

# --- Paso 2: Generar config para bootc-image-builder ---
log "Preparando configuración de instalación..."

mkdir -p "$OUTPUT_DIR"

# Generar hash de contraseña para el usuario default
PASS_HASH=$(python3 -c "import crypt; print(crypt.crypt('lifeos', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || \
            openssl passwd -6 lifeos)

CONFIG_FILE="$OUTPUT_DIR/config.json"
cat > "$CONFIG_FILE" << CONFIGEOF
{
  "blueprint": {
    "customizations": {
      "user": [
        {
          "name": "lifeos",
          "password": "${PASS_HASH}",
          "groups": ["wheel"]
        }
      ],
      "kernel": {
        "append": "quiet rhgb"
      }
    }
  }
}
CONFIGEOF

success "Configuración generada"
echo "  Usuario: lifeos"
echo "  Password: lifeos"

# --- Paso 3: Generar imagen con bootc-image-builder ---
log "Generando imagen ${BUILD_TYPE}..."
log "Esto puede tomar 10-20 minutos..."
echo ""

# Limpiar output previo
rm -rf "$OUTPUT_DIR/bootiso" "$OUTPUT_DIR/disk.*" "$OUTPUT_DIR/image"

podman run \
    --rm \
    --privileged \
    --pull=newer \
    --security-opt label=type:unconfined_t \
    -v "$OUTPUT_DIR:/output" \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$CONFIG_FILE:/config.json:ro" \
    "$BIB_IMAGE" \
    --type "$BUILD_TYPE" \
    --rootfs btrfs \
    --local \
    --config /config.json \
    "$IMAGE_NAME"

# --- Paso 4: Renombrar y verificar output ---
TIMESTAMP=$(date +%Y%m%d)
FINAL_FILE=""

case "$BUILD_TYPE" in
    iso)
        SRC=$(find "$OUTPUT_DIR" -name "*.iso" -type f 2>/dev/null | head -1)
        if [[ -n "$SRC" ]]; then
            FINAL_FILE="$OUTPUT_DIR/lifeos-${TIMESTAMP}.iso"
            mv "$SRC" "$FINAL_FILE"
            rm -rf "$OUTPUT_DIR/bootiso"
        fi
        ;;
    vmdk)
        SRC=$(find "$OUTPUT_DIR" -name "*.vmdk" -type f 2>/dev/null | head -1)
        if [[ -n "$SRC" ]]; then
            FINAL_FILE="$OUTPUT_DIR/lifeos-${TIMESTAMP}.vmdk"
            mv "$SRC" "$FINAL_FILE"
        fi
        ;;
    qcow2)
        SRC=$(find "$OUTPUT_DIR" -name "*.qcow2" -type f 2>/dev/null | head -1)
        if [[ -n "$SRC" ]]; then
            FINAL_FILE="$OUTPUT_DIR/lifeos-${TIMESTAMP}.qcow2"
            mv "$SRC" "$FINAL_FILE"
        fi
        ;;
    raw)
        SRC=$(find "$OUTPUT_DIR" -name "*.raw" -type f 2>/dev/null | head -1)
        if [[ -n "$SRC" ]]; then
            FINAL_FILE="$OUTPUT_DIR/lifeos-${TIMESTAMP}.raw"
            mv "$SRC" "$FINAL_FILE"
        fi
        ;;
esac

if [[ -z "$FINAL_FILE" ]] || [[ ! -f "$FINAL_FILE" ]]; then
    error "No se generó el archivo de salida. Revisa los logs arriba."
fi

# Generar checksum
sha256sum "$FINAL_FILE" > "${FINAL_FILE}.sha256"

# Limpiar config temporal
rm -f "$CONFIG_FILE"

# --- Resultado ---
echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  LifeOS ${BUILD_TYPE} generado exitosamente!${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "  Archivo:  ${CYAN}${FINAL_FILE}${NC}"
echo -e "  Tamaño:   $(du -h "$FINAL_FILE" | cut -f1)"
echo -e "  SHA256:   $(cut -d' ' -f1 "${FINAL_FILE}.sha256")"
echo ""

case "$BUILD_TYPE" in
    iso)
        echo -e "${YELLOW}Para usar en VirtualBox:${NC}"
        echo "  1. Crear nueva VM (Fedora 64-bit, 4GB RAM, 40GB disco)"
        echo "  2. Montar el ISO como unidad óptica"
        echo "  3. Arrancar e instalar"
        echo ""
        echo -e "${YELLOW}Para copiar a Windows:${NC}"
        echo "  cp $FINAL_FILE /mnt/c/Users/\$USER/Downloads/"
        ;;
    vmdk)
        echo -e "${YELLOW}Para usar en VirtualBox:${NC}"
        echo "  1. Crear nueva VM (Fedora 64-bit, 4GB RAM)"
        echo "  2. En almacenamiento, usar disco existente: seleccionar el .vmdk"
        echo "  3. Arrancar la VM"
        echo ""
        echo -e "${YELLOW}Para copiar a Windows:${NC}"
        echo "  cp $FINAL_FILE /mnt/c/Users/\$USER/Downloads/"
        ;;
    qcow2)
        echo -e "${YELLOW}Para usar con QEMU/KVM:${NC}"
        echo "  qemu-system-x86_64 -m 4G -drive file=$FINAL_FILE,format=qcow2 -enable-kvm"
        ;;
esac

echo ""
echo "  Usuario: lifeos / Password: lifeos"
echo "  Baseline de seguridad: Secure Boot + LUKS2 se validan en runtime"
echo "  (solo para laboratorio: crear /etc/lifeos/allow-insecure-platform para bypass)"
echo ""
