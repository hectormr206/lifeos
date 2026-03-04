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
#   - Root o rootless (este script detecta y usa el storage adecuado)
#
# Desde Windows (WSL2):
#   wsl -d Ubuntu -- sudo bash /ruta/al/proyecto/scripts/generate-iso-simple.sh
#===============================================================================

set -euo pipefail

# --- Configuración ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${LIFEOS_OUTPUT_DIR:-${PROJECT_ROOT}/output}"
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

if [[ $EUID -eq 0 ]]; then
    CONTAINERS_STORAGE="/var/lib/containers/storage"
    log "Ejecutando como root"
else
    CONTAINERS_STORAGE="${HOME}/.local/share/containers/storage"
    warn "Ejecutando en modo rootless (sin sudo)"
fi

if [[ ! -d "$CONTAINERS_STORAGE" ]]; then
    error "No se encontró el storage de podman en: $CONTAINERS_STORAGE"
fi

# Verificar que BUILD_TYPE es válido
case "$BUILD_TYPE" in
    iso|vmdk|qcow2|raw) ;;
    *) error "Tipo de build inválido: $BUILD_TYPE. Usa: iso, vmdk, qcow2 o raw" ;;
esac

# ISO necesita loop devices para crear efiboot.img (mkfs.fat en osbuild).
# En rootless sin permiso a /dev/loop-control fallará al final tras varios minutos.
if [[ "$BUILD_TYPE" == "iso" ]] && [[ $EUID -ne 0 ]] && [[ ! -w /dev/loop-control ]]; then
    error "No hay permisos de escritura sobre /dev/loop-control. Para generar ISO usa:
  1) sudo ./scripts/generate-iso-simple.sh --type iso --image \"$IMAGE_NAME\"
  2) o agrega tu usuario al grupo disk y reinicia sesión:
     sudo usermod -aG disk $USER"
fi

success "Prerequisitos OK"
log "Directorio de salida: $OUTPUT_DIR"

# --- Paso 1: Construir la imagen si no existe ---
log "Verificando imagen del contenedor..."

NEEDS_BUILD=0
if ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
    NEEDS_BUILD=1
else
    success "Imagen encontrada: $IMAGE_NAME"
    # Validación extra para ISO: algunas imágenes antiguas no traen shimx64.efi
    # en /boot/efi/EFI/fedora y fallan en org.osbuild.grub2.iso.
    if [[ "$BUILD_TYPE" == "iso" ]]; then
        if ! podman run --rm "$IMAGE_NAME" test -f /boot/efi/EFI/fedora/shimx64.efi >/dev/null 2>&1; then
            warn "La imagen existe pero no incluye /boot/efi/EFI/fedora/shimx64.efi"
            warn "Se reconstruirá automáticamente para evitar fallo en grub2.iso"
            NEEDS_BUILD=1
        fi
    fi
fi

if [[ "$NEEDS_BUILD" -eq 1 ]]; then
    log "Construyendo imagen '$IMAGE_NAME'..."
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
fi

# --- Paso 2: Generar config para bootc-image-builder ---
log "Preparando configuración de instalación..."

if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
    if [[ -z "${LIFEOS_OUTPUT_DIR:-}" ]]; then
        OUTPUT_DIR="/tmp/lifeos-output-${USER}"
        warn "Sin permisos en output del proyecto. Usando fallback: $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR" || error "No se pudo crear el directorio fallback: $OUTPUT_DIR"
    else
        error "No se pudo crear/escribir en LIFEOS_OUTPUT_DIR: $OUTPUT_DIR"
    fi
fi

if [[ ! -w "$OUTPUT_DIR" ]]; then
    if [[ -z "${LIFEOS_OUTPUT_DIR:-}" ]]; then
        OUTPUT_DIR="/tmp/lifeos-output-${USER}"
        warn "Directorio no escribible. Usando fallback: $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR" || error "No se pudo crear el directorio fallback: $OUTPUT_DIR"
    else
        error "LIFEOS_OUTPUT_DIR no es escribible: $OUTPUT_DIR"
    fi
fi

log "Output efectivo: $OUTPUT_DIR"

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
rm -rf "$OUTPUT_DIR/bootiso" "$OUTPUT_DIR/image"
rm -f "$OUTPUT_DIR/disk.raw" "$OUTPUT_DIR/disk.qcow2" "$OUTPUT_DIR/disk.vmdk"

# bootc-image-builder usa --type anaconda-iso para generar ISOs instalables.
# Esto produce un ISO con Anaconda + kickstart automatizado que escribe la imagen
# bootc al disco. No usar bootc-installer/--in-vm (experimental, rompe Anaconda).
BIB_TYPE="$BUILD_TYPE"
BIB_EXTRA_ARGS=()
if [[ "$BUILD_TYPE" == "iso" ]]; then
    BIB_TYPE="anaconda-iso"
fi

PODMAN_RUN_ARGS=(
    --rm
    --privileged
    --pull=newer
    --security-opt
    label=type:unconfined_t
    -v
    "$OUTPUT_DIR:/output"
    -v
    "$CONTAINERS_STORAGE:/var/lib/containers/storage"
    -v
    "$CONFIG_FILE:/config.json:ro"
)

# Rootless + ISO: osbuild necesita acceso explícito a loop devices en algunos hosts.
if [[ "$BUILD_TYPE" == "iso" ]] && [[ $EUID -ne 0 ]]; then
    PODMAN_RUN_ARGS+=(--group-add keep-groups)
    PODMAN_RUN_ARGS+=(--device /dev/loop-control:/dev/loop-control)
    for loopdev in /dev/loop[0-9]*; do
        [[ -b "$loopdev" ]] || continue
        PODMAN_RUN_ARGS+=(--device "$loopdev:$loopdev")
    done
fi

podman run \
    "${PODMAN_RUN_ARGS[@]}" \
    "$BIB_IMAGE" \
    --type "$BIB_TYPE" \
    --rootfs btrfs \
    "${BIB_EXTRA_ARGS[@]}" \
    --config /config.json \
    "$IMAGE_NAME"

# --- Paso 4: Renombrar y verificar output ---
TIMESTAMP_DATE=$(date +%Y%m%d)
TIMESTAMP_FULL=$(date +%Y%m%d-%H%M%S)
FINAL_FILE=""

case "$BUILD_TYPE" in
    iso)
        SRC="$OUTPUT_DIR/bootiso/install.iso"
        if [[ -f "$SRC" ]]; then
            rm -f "$OUTPUT_DIR"/lifeos-*.iso
            FINAL_FILE="$OUTPUT_DIR/lifeos-latest.iso"
            mv "$SRC" "$FINAL_FILE"
            rm -rf "$OUTPUT_DIR/bootiso"
        fi
        ;;
    vmdk)
        SRC="$OUTPUT_DIR/disk.vmdk"
        if [[ -f "$SRC" ]]; then
            rm -f "$OUTPUT_DIR"/lifeos-*.vmdk
            FINAL_FILE="$OUTPUT_DIR/lifeos-latest.vmdk"
            mv "$SRC" "$FINAL_FILE"
        fi
        ;;
    qcow2)
        SRC="$OUTPUT_DIR/disk.qcow2"
        if [[ -f "$SRC" ]]; then
            rm -f "$OUTPUT_DIR"/lifeos-*.qcow2
            FINAL_FILE="$OUTPUT_DIR/lifeos-latest.qcow2"
            mv "$SRC" "$FINAL_FILE"
        fi
        ;;
    raw)
        SRC="$OUTPUT_DIR/disk.raw"
        if [[ -f "$SRC" ]]; then
            rm -f "$OUTPUT_DIR"/lifeos-*.raw
            FINAL_FILE="$OUTPUT_DIR/lifeos-latest.raw"
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
