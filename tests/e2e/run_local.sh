#!/bin/bash
# tests/e2e/run_local.sh
# Helper script to run E2E tests locally with proper setup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_help() {
    cat << EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
    prepare     Install dependencies and setup environment
    build-iso   Build the test ISO
    run         Run the E2E tests
    clean       Clean up test artifacts and VMs
    status      Check test environment status
    help        Show this help message

Options:
    --verbose       Enable verbose output
    --no-cache      Don't use build cache
    --no-cleanup    Don't cleanup VM after test

Examples:
    $0 prepare                  # Setup environment
    $0 build-iso                # Build ISO for testing
    $0 run                      # Run tests
    $0 run --no-cleanup         # Run and keep VM for debugging
    $0 clean                    # Clean up everything
    $0 status                   # Check environment

EOF
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        return 1
    fi
    return 0
}

cmd_prepare() {
    log_info "Installing dependencies..."
    
    # Detect OS
    if [ -f /etc/debian_version ]; then
        log_info "Detected Debian/Ubuntu"
        sudo apt-get update
        sudo apt-get install -y \
            qemu-kvm \
            libvirt-daemon-system \
            virtinst \
            sshpass \
            xorriso \
            mtools \
            openssl
    elif [ -f /etc/fedora-release ]; then
        log_info "Detected Fedora"
        sudo dnf install -y \
            qemu-kvm \
            libvirt \
            virt-install \
            sshpass \
            xorriso \
            mtools \
            openssl
    else
        log_error "Unsupported OS. Please install dependencies manually:"
        echo "  - qemu-kvm"
        echo "  - libvirt"
        echo "  - virt-install"
        echo "  - sshpass"
        echo "  - xorriso"
        echo "  - mtools"
        echo "  - openssl"
        exit 1
    fi
    
    # Add user to groups
    log_info "Adding user to kvm and libvirt groups..."
    sudo usermod -aG kvm,libvirt $(whoami) 2>/dev/null || true
    
    # Start libvirtd
    log_info "Starting libvirtd service..."
    sudo systemctl enable --now libvirtd || true
    
    log_info "✓ Environment prepared"
    log_warn "You may need to log out and back in for group changes to take effect"
}

cmd_build_iso() {
    local no_cache="${1:-false}"
    
    log_info "Building LifeOS binaries..."
    cd "$PROJECT_ROOT"
    
    if [ "$no_cache" = true ]; then
        cargo clean
    fi
    
    make build
    
    log_info "Generating test ISO..."
    if [ -f scripts/generate-iso-simple.sh ]; then
        bash scripts/generate-iso-simple.sh
    elif [ -f scripts/generate-iso.sh ]; then
        bash scripts/generate-iso.sh
    else
        log_error "No ISO generation script found"
        exit 1
    fi
    
    # Verify ISO
    if [ -f "build/lifeos.iso" ]; then
        log_info "✓ ISO created successfully: $(ls -lh build/lifeos.iso | awk '{print $5}')"
    else
        log_error "ISO creation failed"
        exit 1
    fi
}

cmd_run() {
    local verbose=false
    local no_cleanup=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --verbose)
                verbose=true
                shift
                ;;
            --no-cleanup)
                no_cleanup=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
    
    # Check ISO exists
    if [ ! -f "$PROJECT_ROOT/build/lifeos.iso" ]; then
        log_warn "ISO not found. Building it first..."
        cmd_build_iso
    fi
    
    # Run tests
    log_info "Running E2E tests..."
    cd "$SCRIPT_DIR"
    
    local args=("--iso" "$PROJECT_ROOT/build/lifeos.iso")
    
    if [ "$verbose" = true ]; then
        args+=("--verbose")
    fi
    
    if [ "$no_cleanup" = true ]; then
        args+=("--no-cleanup")
    fi
    
    ./test_bootc_upgrade_rollback.sh "${args[@]}"
}

cmd_clean() {
    log_info "Cleaning up test artifacts..."
    
    # Stop and remove VM
    if virsh list --name --state-running | grep -q "lifeos-bootc-test"; then
        log_info "Destroying test VM..."
        sudo virsh destroy lifeos-bootc-test 2>/dev/null || true
    fi
    
    if virsh list --all --name | grep -q "lifeos-bootc-test"; then
        log_info "Undefining test VM..."
        sudo virsh undefine lifeos-bootc-test --nvram 2>/dev/null || true
    fi
    
    # Remove disk images
    log_info "Removing disk images..."
    sudo rm -f /var/lib/libvirt/images/lifeos-bootc-test.qcow2 2>/dev/null || true
    
    # Kill stray QEMU processes
    pkill -f "qemu-system-x86_64.*lifeos-bootc-test" 2>/dev/null || true
    
    # Remove logs
    log_info "Removing test logs..."
    rm -f /tmp/bootc-test-*.log 2>/dev/null || true
    
    # Remove build artifacts (optional)
    read -p "Remove build artifacts (ISO, binaries)? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Removing build artifacts..."
        cd "$PROJECT_ROOT"
        rm -rf build/ target/
    fi
    
    log_info "✓ Cleanup complete"
}

cmd_status() {
    echo -e "${BLUE}E2E Test Environment Status${NC}"
    echo "================================"
    echo ""
    
    # Check dependencies
    echo -e "${BLUE}Dependencies:${NC}"
    for cmd in qemu-system-x86_64 virsh virt-install sshpass; do
        if check_command "$cmd"; then
            echo -e "  ${GREEN}✓${NC} $cmd: $(command -v $cmd)"
        else
            echo -e "  ${RED}✗${NC} $cmd: NOT INSTALLED"
        fi
    done
    echo ""
    
    # Check KVM
    echo -e "${BLUE}Virtualization:${NC}"
    if [ -e /dev/kvm ]; then
        echo -e "  ${GREEN}✓${NC} KVM: Available"
        ls -l /dev/kvm | awk '{print "     Permissions:", $1, "Owner:", $3":"$4}'
    else
        echo -e "  ${RED}✗${NC} KVM: Not available"
    fi
    echo ""
    
    # Check libvirt
    echo -e "${BLUE}Libvirt:${NC}"
    if systemctl is-active --quiet libvirtd; then
        echo -e "  ${GREEN}✓${NC} libvirtd: Running"
    else
        echo -e "  ${YELLOW}○${NC} libvirtd: Not running"
    fi
    echo ""
    
    # Check groups
    echo -e "${BLUE}User Groups:${NC}"
    if groups | grep -q '\bkvm\b'; then
        echo -e "  ${GREEN}✓${NC} kvm group: Member"
    else
        echo -e "  ${RED}✗${NC} kvm group: Not a member"
    fi
    
    if groups | grep -q '\blibvirt\b'; then
        echo -e "  ${GREEN}✓${NC} libvirt group: Member"
    else
        echo -e "  ${YELLOW}○${NC} libvirt group: Not a member (optional)"
    fi
    echo ""
    
    # Check ISO
    echo -e "${BLUE}Test Artifacts:${NC}"
    if [ -f "$PROJECT_ROOT/build/lifeos.iso" ]; then
        local iso_size=$(ls -lh "$PROJECT_ROOT/build/lifeos.iso" | awk '{print $5}')
        echo -e "  ${GREEN}✓${NC} ISO: $iso_size"
    else
        echo -e "  ${YELLOW}○${NC} ISO: Not built"
    fi
    echo ""
    
    # Check running VMs
    echo -e "${BLUE}Test VMs:${NC}"
    if virsh list --name --state-running 2>/dev/null | grep -q "lifeos-bootc-test"; then
        echo -e "  ${YELLOW}○${NC} lifeos-bootc-test: Running"
    else
        echo -e "  ${GREEN}✓${NC} lifeos-bootc-test: Not running"
    fi
    echo ""
}

# Main
case "${1:-help}" in
    prepare)
        cmd_prepare
        ;;
    build-iso)
        local no_cache=false
        [ "${2:-}" = "--no-cache" ] && no_cache=true
        cmd_build_iso "$no_cache"
        ;;
    run)
        shift
        cmd_run "$@"
        ;;
    clean)
        cmd_clean
        ;;
    status)
        cmd_status
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        log_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
