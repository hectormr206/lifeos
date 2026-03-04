#!/bin/bash
#===============================================================================
# LifeOS ISO Generator
#===============================================================================
# Generates bootable ISO images from LifeOS container images using
# bootc-image-builder for real hardware installation.
#
# Usage: ./scripts/generate-iso.sh [options]
#===============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
DEFAULT_LOCAL_IMAGE="localhost/lifeos:latest"
DEFAULT_REMOTE_IMAGE="ghcr.io/hectormr/lifeos:latest"
IMAGE_TAG="${LIFEOS_IMAGE:-}"
OUTPUT_DIR="${LIFEOS_OUTPUT:-./output}"
ISO_NAME="${LIFEOS_ISO_NAME:-lifeos}"
ISO_VERSION="${LIFEOS_VERSION:-$(date +%Y%m%d)}"
TARGET_ARCH="${LIFEOS_ARCH:-x86_64}"
BUILD_TYPE="${LIFEOS_BUILD_TYPE:-iso}"  # iso, raw, qcow2, vmdk
ROOTFS_SIZE="${LIFEOS_ROOTFS_SIZE:-20}"

# Show help
show_help() {
    cat << EOF
LifeOS ISO Generator

Generates bootable installation media from LifeOS container images.

USAGE:
    $(basename "$0") [OPTIONS]

OPTIONS:
    -i, --image TAG         Container image to use (default: auto-detected)
    -o, --output DIR        Output directory (default: $OUTPUT_DIR)
    -n, --name NAME         ISO name prefix (default: $ISO_NAME)
    -v, --version VER       Version string (default: $ISO_VERSION)
    -a, --arch ARCH         Target architecture: x86_64, aarch64 (default: $TARGET_ARCH)
    -t, --type TYPE         Build type: iso, raw, qcow2, vmdk (default: $BUILD_TYPE)
    -s, --size SIZE         Root filesystem size in GB (default: $ROOTFS_SIZE)
    --local                 Use local podman image instead of pulling
    --no-verify             Skip image verification
    --vm-test               Test the generated ISO in a VM
    -h, --help              Show this help message

EXAMPLES:
    # Generate standard ISO
    ./scripts/generate-iso.sh

    # Generate ISO from specific image
    ./scripts/generate-iso.sh -i localhost/lifeos:custom

    # Generate raw disk image for VM
    ./scripts/generate-iso.sh -t raw -s 50

    # Generate and test in VM
    ./scripts/generate-iso.sh --vm-test

ENVIRONMENT:
    LIFEOS_IMAGE            Default container image
    LIFEOS_OUTPUT           Default output directory
    LIFEOS_VERSION          Default version string
EOF
}

resolve_image_tag() {
    if [[ -n "$IMAGE_TAG" ]]; then
        return
    fi

    if [[ "${USE_LOCAL_IMAGE:-false}" == true ]]; then
        IMAGE_TAG="$DEFAULT_LOCAL_IMAGE"
        return
    fi

    if podman image exists "$DEFAULT_LOCAL_IMAGE"; then
        IMAGE_TAG="$DEFAULT_LOCAL_IMAGE"
        USE_LOCAL_IMAGE=true
        echo -e "${YELLOW}Auto-selected local image: $IMAGE_TAG${NC}"
    else
        IMAGE_TAG="$DEFAULT_REMOTE_IMAGE"
    fi
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--image)
                IMAGE_TAG="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -n|--name)
                ISO_NAME="$2"
                shift 2
                ;;
            -v|--version)
                ISO_VERSION="$2"
                shift 2
                ;;
            -a|--arch)
                TARGET_ARCH="$2"
                shift 2
                ;;
            -t|--type)
                BUILD_TYPE="$2"
                shift 2
                ;;
            -s|--size)
                ROOTFS_SIZE="$2"
                shift 2
                ;;
            --local)
                USE_LOCAL_IMAGE=true
                shift
                ;;
            --no-verify)
                SKIP_VERIFY=true
                shift
                ;;
            --vm-test)
                VM_TEST=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                echo -e "${RED}Error: Unknown option $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done
}

# Check prerequisites
check_prerequisites() {
    echo -e "${BLUE}Checking prerequisites...${NC}"
    
    local missing=()
    
    # Check for podman
    if ! command -v podman &> /dev/null; then
        missing+=("podman")
    fi
    
    # Check for qemu-img (for VM testing)
    if [[ "${VM_TEST:-false}" == true ]] && ! command -v qemu-img &> /dev/null; then
        echo -e "${YELLOW}Warning: qemu-img not found, VM testing will be skipped${NC}"
        VM_TEST=false
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required tools: ${missing[*]}${NC}"
        echo "Please install them and try again."
        exit 1
    fi
    
    # Check disk space (need at least 20GB free)
    local available
    available=$(df -BG "$(pwd)" | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ $available -lt 20 ]]; then
        echo -e "${YELLOW}Warning: Low disk space (${available}GB available, 20GB recommended)${NC}"
    fi
    
    echo -e "${GREEN}✓ Prerequisites met${NC}"
}

# Pull or verify image
prepare_image() {
    echo -e "${BLUE}Preparing container image...${NC}"
    
    if [[ "${USE_LOCAL_IMAGE:-false}" == true ]]; then
        echo "Using local image: $IMAGE_TAG"
        if ! podman image exists "$IMAGE_TAG"; then
            echo -e "${RED}Error: Local image $IMAGE_TAG not found${NC}"
            exit 1
        fi
    else
        echo "Pulling image: $IMAGE_TAG"
        podman pull "$IMAGE_TAG"
    fi
    
    # Verify image has bootc metadata
    if [[ "${SKIP_VERIFY:-false}" != true ]]; then
        echo "Verifying bootc compatibility..."
        if ! podman run --rm "$IMAGE_TAG" bootc --help &> /dev/null; then
            echo -e "${YELLOW}Warning: Image may not be bootc-compatible${NC}"
        fi
    fi
    
    echo -e "${GREEN}✓ Image ready${NC}"
}

# Generate ISO using bootc-image-builder
generate_iso() {
    echo -e "${BLUE}Generating $BUILD_TYPE image...${NC}"
    
    mkdir -p "$OUTPUT_DIR"
    
    local bib_image="quay.io/centos-bootc/bootc-image-builder:latest"
    local output_file="${OUTPUT_DIR}/${ISO_NAME}-${ISO_VERSION}-${TARGET_ARCH}"
    
    # Prepare bootc-image-builder options
    local bib_opts=()
    bib_opts+=("--type" "$BUILD_TYPE")
    bib_opts+=("--rootfs" "btrfs")
    bib_opts+=("--local")
    
    if [[ "$TARGET_ARCH" == "aarch64" ]]; then
        bib_opts+=("--target-arch" "aarch64")
    fi
    
    # Generar un hash válido para la contraseña 'lifeos'
    local pass_hash
    pass_hash=$(python3 -c "import crypt; print(crypt.crypt('lifeos', crypt.mksalt(crypt.METHOD_SHA512)))" 2>/dev/null || \
                openssl passwd -6 lifeos)

    local iso_volume_id="${LIFEOS_ISO_VOLUME_ID:-LIFEOS_INSTALL}"
    local iso_application_id="${LIFEOS_ISO_APPLICATION_ID:-LIFEOS_INSTALLER}"
    local iso_publisher="${LIFEOS_ISO_PUBLISHER:-LIFEOS}"

    # Escribir la configuración a un archivo temporal local
    local tmp_config=$(mktemp config-XXXXXX.json)
    if [[ "$BUILD_TYPE" == "iso" ]]; then
    cat << CONFIG > "$tmp_config"
{
  "blueprint": {
    "customizations": {
      "user": [
        {
          "name": "lifeos",
          "password": "${pass_hash}",
          "key": "",
          "groups": ["wheel"]
        }
      ],
      "kernel": {
        "append": "quiet rhgb"
      },
      "iso": {
        "volume_id": "${iso_volume_id}",
        "application_id": "${iso_application_id}",
        "publisher": "${iso_publisher}"
      },
      "services": {
        "enabled": ["sshd", "chronyd", "cosmic-greeter"]
      }
    }
  }
}
CONFIG
    else
    cat << CONFIG > "$tmp_config"
{
  "blueprint": {
    "customizations": {
      "user": [
        {
          "name": "lifeos",
          "password": "${pass_hash}",
          "key": "",
          "groups": ["wheel"]
        }
      ],
      "kernel": {
        "append": "quiet rhgb"
      },
      "services": {
        "enabled": ["sshd", "chronyd", "cosmic-greeter"]
      }
    }
  }
}
CONFIG
    fi

    # Run bootc-image-builder
    echo "Running bootc-image-builder..."
    if ! podman run \
        --rm \
        --privileged \
        --pull=newer \
        --security-opt label=type:unconfined_t \
        -v "$(pwd)/$OUTPUT_DIR:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        -v "$(pwd)/$tmp_config:/config.json:ro" \
        "$bib_image" \
        "${bib_opts[@]}" \
        "--config" "/config.json" \
        "$IMAGE_TAG"; then
        rm -f "$tmp_config"
        exit 1
    fi
    
    rm -f "$tmp_config"
    # Rename output based on type
    case "$BUILD_TYPE" in
        iso)
            if [[ -f "$OUTPUT_DIR/bootiso/install.iso" ]]; then
                mv "$OUTPUT_DIR/bootiso/install.iso" "${output_file}.iso"
                rm -rf "$OUTPUT_DIR/bootiso"
                echo -e "${GREEN}✓ ISO generated: ${output_file}.iso${NC}"
            fi
            ;;
        raw)
            if [[ -f "$OUTPUT_DIR/disk.raw" ]]; then
                mv "$OUTPUT_DIR/disk.raw" "${output_file}.raw"
                echo -e "${GREEN}✓ Raw image generated: ${output_file}.raw${NC}"
            fi
            ;;
        qcow2)
            if [[ -f "$OUTPUT_DIR/disk.qcow2" ]]; then
                mv "$OUTPUT_DIR/disk.qcow2" "${output_file}.qcow2"
                echo -e "${GREEN}✓ QCOW2 image generated: ${output_file}.qcow2${NC}"
            fi
            ;;
        vmdk)
            if [[ -f "$OUTPUT_DIR/disk.vmdk" ]]; then
                mv "$OUTPUT_DIR/disk.vmdk" "${output_file}.vmdk"
                echo -e "${GREEN}✓ VMDK image generated: ${output_file}.vmdk${NC}"
            fi
            ;;
    esac
}

# Generate checksums
generate_checksums() {
    echo -e "${BLUE}Generating checksums...${NC}"
    
    local output_file="${OUTPUT_DIR}/${ISO_NAME}-${ISO_VERSION}-${TARGET_ARCH}"
    
    case "$BUILD_TYPE" in
        iso)
            if [[ -f "${output_file}.iso" ]]; then
                sha256sum "${output_file}.iso" > "${output_file}.iso.sha256"
                echo -e "${GREEN}✓ Checksum: ${output_file}.iso.sha256${NC}"
            fi
            ;;
        raw)
            if [[ -f "${output_file}.raw" ]]; then
                sha256sum "${output_file}.raw" > "${output_file}.raw.sha256"
                echo -e "${GREEN}✓ Checksum: ${output_file}.raw.sha256${NC}"
            fi
            ;;
        qcow2)
            if [[ -f "${output_file}.qcow2" ]]; then
                sha256sum "${output_file}.qcow2" > "${output_file}.qcow2.sha256"
                echo -e "${GREEN}✓ Checksum: ${output_file}.qcow2.sha256${NC}"
            fi
            ;;
        vmdk)
            if [[ -f "${output_file}.vmdk" ]]; then
                sha256sum "${output_file}.vmdk" > "${output_file}.vmdk.sha256"
                echo -e "${GREEN}✓ Checksum: ${output_file}.vmdk.sha256${NC}"
            fi
            ;;
    esac
}

# Test ISO in VM
test_in_vm() {
    echo -e "${BLUE}Testing ISO in virtual machine...${NC}"
    
    local iso_file="${OUTPUT_DIR}/${ISO_NAME}-${ISO_VERSION}-${TARGET_ARCH}.iso"
    
    if [[ ! -f "$iso_file" ]]; then
        echo -e "${RED}Error: ISO file not found: $iso_file${NC}"
        return 1
    fi
    
    echo "Creating test VM..."
    
    # Check available virtualization
    if command -v kvm-ok &> /dev/null && kvm-ok &> /dev/null; then
        echo "Using KVM acceleration"
        local accel="-enable-kvm -cpu host"
    else
        echo "Using TCG emulation (slower)"
        local accel=""
    fi
    
    # Create temporary disk for testing
    local test_disk="${OUTPUT_DIR}/test-disk-${ISO_VERSION}.qcow2"
    qemu-img create -f qcow2 "$test_disk" 40G
    
    echo "Starting VM (Ctrl+A then X to exit)..."
    qemu-system-x86_64 \
        $accel \
        -m 4096 \
        -smp 2 \
        -cdrom "$iso_file" \
        -drive file="$test_disk",format=qcow2,if=virtio \
        -boot d \
        -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
        -display sdl \
        -vga virtio \
        || true
    
    # Cleanup
    rm -f "$test_disk"
    
    echo -e "${GREEN}✓ VM test completed${NC}"
}

# Create metadata file
create_metadata() {
    echo -e "${BLUE}Creating metadata...${NC}"
    
    local metadata_file="${OUTPUT_DIR}/${ISO_NAME}-${ISO_VERSION}-${TARGET_ARCH}.json"
    local image_digest
    image_digest=$(podman inspect "$IMAGE_TAG" --format='{{.Digest}}' 2>/dev/null || echo "unknown")
    
    cat > "$metadata_file" << EOF
{
  "name": "$ISO_NAME",
  "version": "$ISO_VERSION",
  "architecture": "$TARGET_ARCH",
  "type": "$BUILD_TYPE",
  "image": "$IMAGE_TAG",
  "image_digest": "$image_digest",
  "generated_at": "$(date -Iseconds)",
  "rootfs_size_gb": $ROOTFS_SIZE,
  "files": {
    "iso": "${ISO_NAME}-${ISO_VERSION}-${TARGET_ARCH}.iso",
    "sha256": "${ISO_NAME}-${ISO_VERSION}-${TARGET_ARCH}.iso.sha256"
  },
  "requirements": {
    "min_memory_gb": 4,
    "min_disk_gb": $ROOTFS_SIZE,
    "recommended_memory_gb": 8,
    "recommended_disk_gb": 50,
    "secure_boot_required": true,
    "luks2_required": true,
    "tpm2_recommended": true
  }
}
EOF
    
    echo -e "${GREEN}✓ Metadata: $metadata_file${NC}"
}

# Main function
main() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                                                              ║${NC}"
    echo -e "${CYAN}║              LifeOS ISO Generator                            ║${NC}"
    echo -e "${CYAN}║                                                              ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    parse_args "$@"
    resolve_image_tag
    
    echo "Configuration:"
    echo "  Image:      $IMAGE_TAG"
    echo "  Output:     $OUTPUT_DIR"
    echo "  Name:       $ISO_NAME"
    echo "  Version:    $ISO_VERSION"
    echo "  Arch:       $TARGET_ARCH"
    echo "  Type:       $BUILD_TYPE"
    echo "  RootFS:     ${ROOTFS_SIZE}GB"
    echo
    
    check_prerequisites
    prepare_image
    generate_iso
    generate_checksums
    create_metadata
    
    if [[ "${VM_TEST:-false}" == true ]]; then
        test_in_vm
    fi
    
    echo
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ISO generation completed successfully!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo
    echo "Output files:"
    ls -lh "$OUTPUT_DIR/${ISO_NAME}-${ISO_VERSION}-${TARGET_ARCH}"* 2>/dev/null || true
    echo
    echo "Next steps:"
    case "$BUILD_TYPE" in
        iso)
            echo "  For USB:        sudo dd if=${OUTPUT_DIR}/${ISO_NAME}-${ISO_VERSION}-${TARGET_ARCH}.iso of=/dev/sdX bs=4M status=progress"
            echo "  For VirtualBox: Create VM (Fedora 64-bit, 4GB RAM, 40GB disk) and mount the ISO"
            ;;
        vmdk)
            echo "  For VirtualBox: Create VM and attach the .vmdk as existing disk"
            ;;
        qcow2)
            echo "  For QEMU/KVM:   qemu-system-x86_64 -m 4G -drive file=<file>,format=qcow2 -enable-kvm"
            ;;
        raw)
            echo "  For USB:        sudo dd if=<file> of=/dev/sdX bs=4M status=progress"
            ;;
    esac
    echo ""
    echo "  Default login: lifeos / lifeos"
    echo "  Security baseline: Secure Boot + LUKS2 enforced at runtime"
    echo "  (create /etc/lifeos/allow-insecure-platform only for lab/dev bypass)"
}

# Run main function
main "$@"
