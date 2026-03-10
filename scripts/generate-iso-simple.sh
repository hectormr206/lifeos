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
#   ./scripts/generate-iso-simple.sh --install-mode unattended  # Solo CI/lab
#
# Requisitos:
#   - Podman instalado (sudo apt install podman  o  sudo dnf install podman)
#   - Root (bootc-image-builder requiere podman rootful)
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
INSTALL_MODE="${LIFEOS_INSTALL_MODE:-interactive}" # interactive (safe) | unattended (CI/lab)
REBUILD_POLICY="${LIFEOS_REBUILD_POLICY:-auto}"    # auto | always | never
BIB_IMAGE="quay.io/centos-bootc/bootc-image-builder:latest"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
VCS_REF="${VCS_REF:-$(git -C "$PROJECT_ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)}"
NVIDIA_SIGN_KEY_B64="${LIFEOS_NVIDIA_KMOD_SIGN_KEY_B64:-}"
NVIDIA_SIGN_CERT_DER_B64="${LIFEOS_NVIDIA_KMOD_CERT_DER_B64:-}"

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
        --install-mode|-m) INSTALL_MODE="$2"; shift 2 ;;
        --rebuild) REBUILD_POLICY="always"; shift ;;
        --no-rebuild) REBUILD_POLICY="never"; shift ;;
        --help|-h)
            echo "Uso: $0 [--type iso|vmdk|qcow2|raw] [--image IMAGE] [--install-mode interactive|unattended] [--rebuild|--no-rebuild]"
            echo ""
            echo "Opciones:"
            echo "  --type TYPE           Formato de salida: iso (default), vmdk, qcow2, raw"
            echo "  --image IMAGE         Imagen OCI a usar (default: localhost/lifeos:latest)"
            echo "  --install-mode MODE   Modo instalador ISO: interactive (default, seleccion manual de disco)"
            echo "                        o unattended (auto, puede borrar disco completo)"
            echo "  --rebuild             Fuerza reconstruccion rootful de la imagen antes de generar artefacto"
            echo "  --no-rebuild          Reutiliza la imagen existente aunque sea localhost/*"
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
    error "bootc-image-builder requiere podman rootful. Ejecuta con: sudo ./scripts/generate-iso-simple.sh --type $BUILD_TYPE --image \"$IMAGE_NAME\""
fi

if [[ -n "$NVIDIA_SIGN_KEY_B64" && -n "$NVIDIA_SIGN_CERT_DER_B64" ]]; then
    log "Firma NVIDIA Secure Boot habilitada (build args presentes)"
else
    warn "Firma NVIDIA Secure Boot deshabilitada (build args ausentes)"
fi

CONTAINERS_STORAGE="/var/lib/containers/storage"
log "Ejecutando como root"

if [[ ! -d "$CONTAINERS_STORAGE" ]]; then
    error "No se encontró el storage de podman en: $CONTAINERS_STORAGE"
fi

# Verificar que BUILD_TYPE es válido
case "$BUILD_TYPE" in
    iso|vmdk|qcow2|raw) ;;
    *) error "Tipo de build inválido: $BUILD_TYPE. Usa: iso, vmdk, qcow2 o raw" ;;
esac

case "$INSTALL_MODE" in
    interactive|unattended) ;;
    *) error "Modo de instalación inválido: $INSTALL_MODE. Usa: interactive o unattended" ;;
esac

case "$REBUILD_POLICY" in
    auto|always|never) ;;
    *) error "Politica de rebuild invalida: $REBUILD_POLICY. Usa: auto, always o never" ;;
esac

# Opciones de etiqueta para medio ISO (solo aplican cuando BUILD_TYPE=iso)
ISO_VOLUME_ID="${LIFEOS_ISO_VOLUME_ID:-LIFEOS_INSTALL}"
ISO_APPLICATION_ID="${LIFEOS_ISO_APPLICATION_ID:-LIFEOS_INSTALLER}"
ISO_PUBLISHER="${LIFEOS_ISO_PUBLISHER:-LIFEOS}"

success "Prerequisitos OK"
log "Directorio de salida: $OUTPUT_DIR"

# --- Paso 1: Construir la imagen si no existe ---
log "Verificando imagen del contenedor..."

NEEDS_BUILD=0
if [[ "$REBUILD_POLICY" == "always" ]]; then
    NEEDS_BUILD=1
    log "Reconstruccion forzada solicitada"
elif [[ "$REBUILD_POLICY" == "auto" && "$IMAGE_NAME" == localhost/* ]]; then
    NEEDS_BUILD=1
    log "Imagen local localhost/* detectada; se reconstruira en storage rootful para evitar divergencia rootless/rootful"
elif ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
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
        --build-arg "BUILD_DATE=${BUILD_DATE}" \
        --build-arg "VCS_REF=${VCS_REF}" \
        --build-arg "LIFEOS_NVIDIA_KMOD_SIGN_KEY_B64=${NVIDIA_SIGN_KEY_B64}" \
        --build-arg "LIFEOS_NVIDIA_KMOD_CERT_DER_B64=${NVIDIA_SIGN_CERT_DER_B64}" \
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
CONFIG_TARGET="/config.json"
if [[ "$BUILD_TYPE" == "iso" && "$INSTALL_MODE" == "interactive" ]]; then
CONFIG_FILE="$OUTPUT_DIR/config.toml"
CONFIG_TARGET="/config.toml"
cat > "$CONFIG_FILE" << CONFIGEOF
[customizations.installer.kickstart]
contents = """
graphical
lang es_MX.UTF-8
keyboard latam
timezone UTC --utc
network --bootproto=dhcp --device=link --activate --onboot=on
rootpw --lock
user --name=lifeos --password=${PASS_HASH} --iscrypted --groups=wheel
bootloader --append="quiet rhgb"
reboot
"""

[customizations.iso]
volume_id = "${ISO_VOLUME_ID}"
application_id = "${ISO_APPLICATION_ID}"
publisher = "${ISO_PUBLISHER}"
CONFIGEOF
elif [[ "$BUILD_TYPE" == "iso" ]]; then
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
      },
      "iso": {
        "volume_id": "${ISO_VOLUME_ID}",
        "application_id": "${ISO_APPLICATION_ID}",
        "publisher": "${ISO_PUBLISHER}"
      }
    }
  }
}
CONFIGEOF
else
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
fi

success "Configuración generada"
echo "  Usuario: lifeos"
echo "  Password: lifeos"
echo "  Install mode: $INSTALL_MODE"
if [[ "$BUILD_TYPE" == "iso" && "$INSTALL_MODE" == "interactive" ]]; then
    echo "  Disco destino: seleccion manual en Anaconda"
fi

# --- Paso 3: Generar imagen con bootc-image-builder ---
log "Generando imagen ${BUILD_TYPE}..."
log "Esto puede tomar 10-20 minutos..."
echo ""

# Limpiar output previo
rm -rf "$OUTPUT_DIR/bootiso" "$OUTPUT_DIR/image"
rm -f "$OUTPUT_DIR/disk.raw" "$OUTPUT_DIR/disk.qcow2" "$OUTPUT_DIR/disk.vmdk"

# bootc-image-builder usa --type anaconda-iso para generar ISOs instalables.
# En modo interactive el usuario selecciona manualmente el disco destino.
# En modo unattended Anaconda usa kickstart automático (potencialmente destructivo).
# No usar bootc-installer/--in-vm (experimental, rompe Anaconda).
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
    "$CONFIG_FILE:$CONFIG_TARGET:ro"
)

podman run \
    "${PODMAN_RUN_ARGS[@]}" \
    "$BIB_IMAGE" \
    --type "$BIB_TYPE" \
    --rootfs btrfs \
    "${BIB_EXTRA_ARGS[@]}" \
    --config "$CONFIG_TARGET" \
    "$IMAGE_NAME"

# --- Paso 4: Renombrar y verificar output ---
TIMESTAMP_DATE=$(date +%Y%m%d)
TIMESTAMP_FULL=$(date +%Y%m%d-%H%M%S)
FINAL_FILE=""

case "$BUILD_TYPE" in
    iso)
        SRC="$OUTPUT_DIR/bootiso/install.iso"
        if [[ ! -f "$SRC" ]]; then
            SRC=$(find "$OUTPUT_DIR" -name "install.iso" -o -name "*.iso" 2>/dev/null | head -1)
        fi
        if [[ -n "$SRC" && -f "$SRC" ]]; then
            rm -f "$OUTPUT_DIR"/lifeos-*.iso
            FINAL_FILE="$OUTPUT_DIR/lifeos-latest.iso"
            mv "$SRC" "$FINAL_FILE"
            rm -rf "$OUTPUT_DIR/bootiso"
        fi
        ;;
    vmdk)
        SRC="$OUTPUT_DIR/disk.vmdk"
        if [[ ! -f "$SRC" ]]; then
            SRC=$(find "$OUTPUT_DIR" -name "disk.vmdk" -o -name "*.vmdk" 2>/dev/null | head -1)
        fi
        if [[ -n "$SRC" && -f "$SRC" ]]; then
            rm -f "$OUTPUT_DIR"/lifeos-*.vmdk
            FINAL_FILE="$OUTPUT_DIR/lifeos-latest.vmdk"
            mv "$SRC" "$FINAL_FILE"
        fi
        ;;
    qcow2)
        SRC="$OUTPUT_DIR/disk.qcow2"
        if [[ ! -f "$SRC" ]]; then
            SRC=$(find "$OUTPUT_DIR" -name "disk.qcow2" -o -name "*.qcow2" 2>/dev/null | head -1)
        fi
        if [[ -n "$SRC" && -f "$SRC" ]]; then
            rm -f "$OUTPUT_DIR"/lifeos-*.qcow2
            FINAL_FILE="$OUTPUT_DIR/lifeos-latest.qcow2"
            mv "$SRC" "$FINAL_FILE"
        fi
        ;;
    raw)
        SRC="$OUTPUT_DIR/disk.raw"
        # bootc-image-builder may place output in image/ subdirectory
        if [[ ! -f "$SRC" ]]; then
            SRC=$(find "$OUTPUT_DIR" -name "disk.raw" -o -name "*.raw" 2>/dev/null | head -1)
        fi
        if [[ -n "$SRC" && -f "$SRC" ]]; then
            rm -f "$OUTPUT_DIR"/lifeos-*.raw
            FINAL_FILE="$OUTPUT_DIR/lifeos-latest.raw"
            mv "$SRC" "$FINAL_FILE"
        fi
        ;;
esac

if [[ -z "$FINAL_FILE" ]] || [[ ! -f "$FINAL_FILE" ]]; then
    warn "Archivos encontrados en $OUTPUT_DIR:"
    find "$OUTPUT_DIR" -type f -name "*.raw" -o -name "*.qcow2" -o -name "*.vmdk" -o -name "*.iso" -o -name "*.img" 2>/dev/null | head -20
    ls -laR "$OUTPUT_DIR" 2>/dev/null | head -40
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
        if [[ "$INSTALL_MODE" == "interactive" ]]; then
            echo "  3. Arrancar, elegir disco destino en Anaconda y continuar instalación"
        else
            echo "  3. Arrancar e instalar (modo unattended: auto-particionado)"
        fi
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
if [[ "$BUILD_TYPE" == "iso" && "$INSTALL_MODE" == "unattended" ]]; then
    warn "Modo unattended puede sobrescribir discos sin pedir confirmación."
fi
echo "  Baseline de seguridad: Secure Boot + LUKS2 se validan en runtime"
echo "  (solo para laboratorio: crear /etc/lifeos/allow-insecure-platform para bypass)"
echo ""
