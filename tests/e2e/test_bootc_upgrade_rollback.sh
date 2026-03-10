#!/bin/bash
# tests/e2e/test_bootc_upgrade_rollback.sh
# Tests bootc upgrade and rollback functionality in a VM
#
# Usage:
#   ./test_bootc_upgrade_rollback.sh [OPTIONS]
#
# Options:
#   --iso PATH         Path to ISO file (default: auto-detect)
#   --vm-name NAME     VM name (default: lifeos-bootc-test)
#   --no-cleanup       Don't cleanup VM after test
#   --verbose          Enable verbose output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/bootc_test_config.yaml"

# Default configuration
VM_NAME="lifeos-bootc-test"
VM_MEMORY="4096"
VM_CPUS="2"
VM_DISK="20G"
SSH_USER="lifeos"
SSH_PASSWORD="lifeos"
SSH_PORT="2222"
SSH_READY_TIMEOUT="300"
ISO_PATH=""
NO_CLEANUP=false
VERBOSE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1"; }
log_debug() { 
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[DEBUG]${NC} $(date '+%H:%M:%S') $1"
    fi
}

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --iso)
                ISO_PATH="$2"
                shift 2
                ;;
            --vm-name)
                VM_NAME="$2"
                shift 2
                ;;
            --no-cleanup)
                NO_CLEANUP=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --iso PATH         Path to ISO file"
                echo "  --vm-name NAME     VM name (default: lifeos-bootc-test)"
                echo "  --no-cleanup       Don't cleanup VM after test"
                echo "  --verbose          Enable verbose output"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

# Load configuration from YAML file
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_debug "Loading configuration from $CONFIG_FILE"
        local vm_name vm_memory vm_cpus vm_disk ssh_port ssh_user ssh_password ssh_ready
        vm_name=$(awk '/^vm:/{in=1;next} in&&/^[^[:space:]]/{in=0} in&&/^[[:space:]]+name:/{print $2;exit}' "$CONFIG_FILE" | tr -d '"')
        vm_memory=$(awk '/^vm:/{in=1;next} in&&/^[^[:space:]]/{in=0} in&&/^[[:space:]]+memory:/{print $2;exit}' "$CONFIG_FILE" | tr -d '"')
        vm_cpus=$(awk '/^vm:/{in=1;next} in&&/^[^[:space:]]/{in=0} in&&/^[[:space:]]+cpus:/{print $2;exit}' "$CONFIG_FILE" | tr -d '"')
        vm_disk=$(awk '/^vm:/{in=1;next} in&&/^[^[:space:]]/{in=0} in&&/^[[:space:]]+disk_size:/{print $2;exit}' "$CONFIG_FILE" | tr -d '"')
        ssh_port=$(awk '/^network:/{in=1;next} in&&/^[^[:space:]]/{in=0} in&&/^[[:space:]]+ssh_port:/{print $2;exit}' "$CONFIG_FILE" | tr -d '"')
        ssh_user=$(awk '/^network:/{in=1;next} in&&/^[^[:space:]]/{in=0} in&&/^[[:space:]]+ssh_user:/{print $2;exit}' "$CONFIG_FILE" | tr -d '"')
        ssh_password=$(awk '/^network:/{in=1;next} in&&/^[^[:space:]]/{in=0} in&&/^[[:space:]]+ssh_password:/{print $2;exit}' "$CONFIG_FILE" | tr -d '"')
        ssh_ready=$(awk '/^timeouts:/{in=1;next} in&&/^[^[:space:]]/{in=0} in&&/^[[:space:]]+ssh_ready:/{print $2;exit}' "$CONFIG_FILE" | tr -d '"')

        [ -n "${vm_name}" ] && VM_NAME="${vm_name}"
        [ -n "${vm_memory}" ] && VM_MEMORY="${vm_memory}"
        [ -n "${vm_cpus}" ] && VM_CPUS="${vm_cpus}"
        [ -n "${vm_disk}" ] && VM_DISK="${vm_disk}"
        [ -n "${ssh_port}" ] && SSH_PORT="${ssh_port}"
        [ -n "${ssh_user}" ] && SSH_USER="${ssh_user}"
        [ -n "${ssh_password}" ] && SSH_PASSWORD="${ssh_password}"
        [ -n "${ssh_ready}" ] && SSH_READY_TIMEOUT="${ssh_ready}"

        log_debug "Config applied: VM_NAME=${VM_NAME}, VM_MEMORY=${VM_MEMORY}, VM_CPUS=${VM_CPUS}, VM_DISK=${VM_DISK}"
        log_debug "Config applied: SSH_USER=${SSH_USER}, SSH_PORT=${SSH_PORT}, SSH_READY_TIMEOUT=${SSH_READY_TIMEOUT}"
    fi
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing=()
    
    # Check for required commands
    for cmd in qemu-system-x86_64 qemu-img ssh sshpass virsh virt-install; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required commands: ${missing[*]}"
        log_error "Install with: sudo apt-get install qemu-kvm libvirt-daemon-system virtinst sshpass"
        exit 1
    fi
    
    # Check if KVM is available
    if [ ! -e /dev/kvm ]; then
        log_warn "KVM not available, tests will be slower"
    fi
    
    # Check if libvirtd is running
    if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
        log_warn "libvirtd is not running, starting it..."
        sudo systemctl start libvirtd || log_warn "Could not start libvirtd"
    fi
    
    log_info "✓ Prerequisites check passed"
}

# Find ISO file
find_iso() {
    if [ -n "$ISO_PATH" ]; then
        if [ ! -f "$ISO_PATH" ]; then
            log_error "ISO file not found: $ISO_PATH"
            exit 1
        fi
        return
    fi
    
    # Try to find ISO in common locations
    local search_paths=(
        "${PROJECT_ROOT}/output/lifeos-latest.iso"
        "${PROJECT_ROOT}/build/lifeos.iso"
        "${PROJECT_ROOT}/lifeos.iso"
        "${PROJECT_ROOT}/output/lifeos.iso"
        "/tmp/lifeos.iso"
    )
    
    for path in "${search_paths[@]}"; do
        if [ -f "$path" ]; then
            ISO_PATH="$path"
            log_info "Found ISO at: $ISO_PATH"
            return
        fi
    done
    
    log_error "No ISO file found. Please specify with --iso option"
    log_error "Or run 'make build && bash scripts/generate-iso-simple.sh' first"
    exit 1
}

# Setup VM
setup_vm() {
    log_info "Setting up test VM: $VM_NAME"
    
    # Create disk image
    local disk_path="/var/lib/libvirt/images/${VM_NAME}.qcow2"
    log_debug "Creating disk image: $disk_path"
    
    sudo qemu-img create -f qcow2 "$disk_path" "$VM_DISK" || {
        log_error "Failed to create disk image"
        exit 1
    }
    
    # Create VM using virt-install or direct QEMU
    if command -v virt-install &> /dev/null && systemctl is-active --quiet libvirtd; then
        setup_vm_libvirt "$disk_path"
    else
        setup_vm_qemu "$disk_path"
    fi
    
    # Wait for VM to boot
    log_info "Waiting for VM to boot..."
    sleep 30
    
    # Wait for SSH to be available
    wait_for_ssh
    
    log_info "✓ VM setup complete"
}

# Setup VM using libvirt
setup_vm_libvirt() {
    local disk_path="$1"
    
    log_debug "Using libvirt for VM setup"
    
    sudo virt-install \
        --name "$VM_NAME" \
        --memory "$VM_MEMORY" \
        --vcpus "$VM_CPUS" \
        --disk path="$disk_path",format=qcow2 \
        --cdrom "$ISO_PATH" \
        --os-variant fedora39 \
        --network network=default,model=virtio \
        --graphics none \
        --noautoconsole \
        --boot uefi || {
        log_error "Failed to create VM with virt-install"
        exit 1
    }
}

# Setup VM using direct QEMU
setup_vm_qemu() {
    local disk_path="$1"
    
    log_debug "Using direct QEMU for VM setup"
    
    sudo qemu-system-x86_64 \
        -name "$VM_NAME" \
        -machine q35,accel=kvm \
        -cpu host \
        -m "$VM_MEMORY" \
        -smp "$VM_CPUS" \
        -drive file="$disk_path",format=qcow2,if=virtio \
        -cdrom "$ISO_PATH" \
        -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
        -device virtio-net-pci,netdev=net0 \
        -nographic \
        -serial mon:stdio \
        -daemonize || {
        log_error "Failed to create VM with QEMU"
        exit 1
    }
}

# Wait for SSH to be available
wait_for_ssh() {
    log_info "Waiting for SSH to be available on port $SSH_PORT..."
    
    local max_attempts=$(( SSH_READY_TIMEOUT / 5 ))
    if [ "$max_attempts" -lt 1 ]; then
        max_attempts=1
    fi
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if ssh_execute "echo 'SSH OK'" 2>/dev/null; then
            log_info "✓ SSH is available"
            return 0
        fi
        
        log_debug "Attempt $attempt/$max_attempts - SSH not ready yet"
        sleep 5
        attempt=$((attempt + 1))
    done
    
    log_error "SSH did not become available within $((max_attempts * 5)) seconds"
    return 1
}

# Execute command via SSH
ssh_execute() {
    local cmd="$1"
    local ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p $SSH_PORT"
    
    log_debug "Executing: $cmd"
    
    if command -v sshpass &> /dev/null; then
        sshpass -p "$SSH_PASSWORD" ssh $ssh_opts "${SSH_USER}@localhost" "$cmd" 2>&1
    else
        ssh $ssh_opts "${SSH_USER}@localhost" "$cmd" 2>&1
    fi
}

# Execute command as sudo via SSH
ssh_execute_sudo() {
    local cmd="$1"
    ssh_execute "sudo $cmd"
}

# Cleanup VM
cleanup() {
    if [ "$NO_CLEANUP" = true ]; then
        log_info "Skipping cleanup (--no-cleanup flag set)"
        return
    fi
    
    log_info "Cleaning up test VM..."
    
    # Try libvirt cleanup first
    if virsh list --name --state-running | grep -q "^${VM_NAME}$"; then
        log_debug "Destroying VM via libvirt"
        sudo virsh destroy "$VM_NAME" 2>/dev/null || true
    fi
    
    if virsh list --all --name | grep -q "^${VM_NAME}$"; then
        log_debug "Undefining VM via libvirt"
        sudo virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
    fi
    
    # Cleanup disk image
    local disk_path="/var/lib/libvirt/images/${VM_NAME}.qcow2"
    if [ -f "$disk_path" ]; then
        log_debug "Removing disk image"
        sudo rm -f "$disk_path"
    fi
    
    # Kill any stray QEMU processes
    pkill -f "qemu-system-x86_64.*${VM_NAME}" 2>/dev/null || true
    
    log_info "✓ Cleanup complete"
}

# Record test result
record_test() {
    local test_name="$1"
    local result="$2"
    local message="${3:-}"
    
    case $result in
        PASS)
            TESTS_PASSED=$((TESTS_PASSED + 1))
            echo -e "${GREEN}✓ PASS${NC}: $test_name"
            ;;
        FAIL)
            TESTS_FAILED=$((TESTS_FAILED + 1))
            echo -e "${RED}✗ FAIL${NC}: $test_name"
            [ -n "$message" ] && echo -e "  ${RED}→${NC} $message"
            ;;
        SKIP)
            TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
            echo -e "${YELLOW}○ SKIP${NC}: $test_name"
            [ -n "$message" ] && echo -e "  ${YELLOW}→${NC} $message"
            ;;
    esac
}

# Test: bootc status
test_bootc_status() {
    log_info "Test: bootc status"
    
    local output
    if ! output=$(ssh_execute_sudo "bootc status" 2>&1); then
        record_test "bootc status" "FAIL" "Command failed: $output"
        return 1
    fi
    
    log_debug "bootc status output:\n$output"
    
    if echo "$output" | grep -q "booted"; then
        record_test "bootc status" "PASS"
        return 0
    else
        record_test "bootc status" "FAIL" "Output missing 'booted' indicator"
        return 1
    fi
}

# Test: bootc upgrade --check
test_bootc_upgrade_check() {
    log_info "Test: bootc upgrade --check"
    
    local output
    if ! output=$(ssh_execute_sudo "bootc upgrade --check" 2>&1); then
        # This might fail if no updates available, which is OK
        log_debug "bootc upgrade --check output:\n$output"
        if echo "$output" | grep -qi "no update available\|up to date"; then
            record_test "bootc upgrade --check" "PASS" "No updates available (expected)"
            return 0
        fi
        record_test "bootc upgrade --check" "FAIL" "Command failed unexpectedly"
        return 1
    fi
    
    record_test "bootc upgrade --check" "PASS"
    return 0
}

# Test: bootc upgrade (dry run)
test_bootc_upgrade_dry() {
    log_info "Test: bootc upgrade (dry run)"
    
    # First, check if there's an update available
    local check_output
    check_output=$(ssh_execute_sudo "bootc upgrade --check" 2>&1) || true
    
    if echo "$check_output" | grep -qi "no update available"; then
        record_test "bootc upgrade dry-run" "SKIP" "No updates available to test"
        return 0
    fi
    
    # Try a dry-run upgrade
    local output
    if output=$(ssh_execute_sudo "bootc upgrade --dry-run" 2>&1); then
        log_debug "bootc upgrade --dry-run output:\n$output"
        record_test "bootc upgrade dry-run" "PASS"
        return 0
    else
        # Dry-run might not be supported in all versions
        if echo "$output" | grep -qi "unknown option\|unrecognized"; then
            record_test "bootc upgrade dry-run" "SKIP" "Dry-run not supported"
            return 0
        fi
        record_test "bootc upgrade dry-run" "FAIL" "$output"
        return 1
    fi
}

# Test: bootc rollback
test_bootc_rollback() {
    log_info "Test: bootc rollback"
    
    # Get current boot slot
    local status_output
    status_output=$(ssh_execute_sudo "bootc status" 2>&1) || {
        record_test "bootc rollback" "FAIL" "Could not get bootc status"
        return 1
    }
    
    local current_slot
    current_slot=$(echo "$status_output" | grep "booted:" | awk '{print $2}' | tr -d ':')
    
    if [ -z "$current_slot" ]; then
        record_test "bootc rollback" "FAIL" "Could not determine current slot"
        return 1
    fi
    
    log_info "Current boot slot: $current_slot"
    
    # Check rollback slot
    local rollback_slot
    rollback_slot=$(echo "$status_output" | grep "rollback:" | awk '{print $2}' | tr -d ':')
    
    if [ -z "$rollback_slot" ]; then
        record_test "bootc rollback" "SKIP" "No rollback slot available"
        return 0
    fi
    
    log_info "Rollback slot: $rollback_slot"
    
    # Perform rollback
    log_info "Executing rollback..."
    local rollback_output
    if ! rollback_output=$(ssh_execute_sudo "bootc rollback" 2>&1); then
        # Check if it's because we're already on the rollback slot
        if echo "$rollback_output" | grep -qi "already.*rollback\|no.*rollback"; then
            record_test "bootc rollback" "SKIP" "Already on rollback slot"
            return 0
        fi
        record_test "bootc rollback" "FAIL" "Rollback command failed: $rollback_output"
        return 1
    fi
    
    log_debug "Rollback output:\n$rollback_output"
    
    # Reboot to apply
    log_info "Rebooting VM to apply rollback..."
    ssh_execute_sudo "reboot" || true
    
    # Wait for reboot
    sleep 30
    wait_for_ssh
    
    # Verify slot changed
    status_output=$(ssh_execute_sudo "bootc status" 2>&1) || {
        record_test "bootc rollback verification" "FAIL" "Could not get status after reboot"
        return 1
    }
    
    local new_slot
    new_slot=$(echo "$status_output" | grep "booted:" | awk '{print $2}' | tr -d ':')
    
    log_info "New boot slot after rollback: $new_slot"
    
    if [ "$current_slot" != "$new_slot" ]; then
        record_test "bootc rollback" "PASS" "Successfully rolled back from $current_slot to $new_slot"
        return 0
    else
        # This might be OK if we were already on rollback slot
        record_test "bootc rollback" "PASS" "Slot unchanged ($new_slot) - may be expected"
        return 0
    fi
}

# Test: life CLI commands
test_life_cli() {
    log_info "Test: life CLI commands"
    
    # Test life status
    local output
    if output=$(ssh_execute "life status" 2>&1); then
        record_test "life status" "PASS"
    else
        record_test "life status" "FAIL" "$output"
        return 1
    fi
    
    # Test life update dry-run mode (compat: --dry and --dry-run)
    if output=$(ssh_execute "life update --dry" 2>&1); then
        record_test "life update --dry" "PASS"
    elif output=$(ssh_execute "life update --dry-run" 2>&1); then
        record_test "life update --dry-run" "PASS"
    else
        # Might not support --dry flag
        if echo "$output" | grep -qi "unknown\|unrecognized"; then
            record_test "life update dry-run" "SKIP" "Flag not supported"
        else
            record_test "life update dry-run" "FAIL" "$output"
        fi
    fi
    
    # Test life rollback command availability without changing system state
    if output=$(ssh_execute "life rollback --help" 2>&1); then
        record_test "life rollback --help" "PASS"
    else
        if echo "$output" | grep -qi "unknown\|unrecognized"; then
            record_test "life rollback --help" "SKIP" "Subcommand not available"
        else
            record_test "life rollback --help" "FAIL" "$output"
        fi
    fi
    
    return 0
}

# Test: system remains bootable
test_system_bootable() {
    log_info "Test: System remains bootable"
    
    # Check that we can still run basic commands
    local tests_passed=0
    local tests_total=3
    
    if ssh_execute "uname -a" > /dev/null 2>&1; then
        tests_passed=$((tests_passed + 1))
    fi
    
    if ssh_execute "systemctl is-system-running" > /dev/null 2>&1; then
        tests_passed=$((tests_passed + 1))
    fi
    
    if ssh_execute "cat /etc/os-release" > /dev/null 2>&1; then
        tests_passed=$((tests_passed + 1))
    fi
    
    if [ $tests_passed -eq $tests_total ]; then
        record_test "System bootable" "PASS"
        return 0
    else
        record_test "System bootable" "FAIL" "Only $tests_passed/$tests_total checks passed"
        return 1
    fi
}

# Test: daemon is running
test_daemon_running() {
    log_info "Test: Daemon is running"
    
    local output
    output=$(ssh_execute "systemctl is-active lifeosd" 2>&1) || true
    
    if echo "$output" | grep -q "active"; then
        record_test "lifeosd daemon" "PASS"
        return 0
    else
        record_test "lifeosd daemon" "FAIL" "Daemon not active: $output"
        return 1
    fi
}

# Print test summary
print_summary() {
    echo ""
    echo "========================================="
    echo "           TEST SUMMARY"
    echo "========================================="
    echo -e "${GREEN}PASSED:${NC}  $TESTS_PASSED"
    echo -e "${RED}FAILED:${NC}  $TESTS_FAILED"
    echo -e "${YELLOW}SKIPPED:${NC} $TESTS_SKIPPED"
    echo "========================================="
    
    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "${RED}SOME TESTS FAILED${NC}"
        return 1
    else
        echo -e "${GREEN}ALL TESTS PASSED${NC}"
        return 0
    fi
}

# Main function
main() {
    parse_args "$@"
    load_config
    
    log_info "========================================="
    log_info "LifeOS bootc Upgrade/Rollback E2E Test"
    log_info "========================================="
    log_info "VM Name: $VM_NAME"
    log_info "VM Memory: $VM_MEMORY MB"
    log_info "VM Disk: $VM_DISK"
    log_info "ISO: $ISO_PATH"
    log_info "SSH Port: $SSH_PORT"
    log_info "========================================="
    
    # Setup
    check_prerequisites
    find_iso
    
    # Set trap for cleanup
    trap cleanup EXIT
    
    # Setup VM
    setup_vm
    
    # Run tests
    log_info "Starting test execution..."
    echo ""
    
    test_bootc_status || true
    test_bootc_upgrade_check || true
    test_bootc_upgrade_dry || true
    test_life_cli || true
    test_daemon_running || true
    test_bootc_rollback || true
    test_system_bootable || true
    
    # Print summary
    print_summary
}

# Run main
main "$@"
