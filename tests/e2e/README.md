# E2E Tests

End-to-end tests for LifeOS bootc upgrade and rollback functionality.

## Overview

These tests validate the complete bootc workflow in a virtual machine environment:
- Boot slot management
- Upgrade operations
- Rollback functionality
- System bootability after changes
- CLI daemon integration

## Prerequisites

### Local Testing

Install required packages:

```bash
# Ubuntu/Debian
sudo apt-get install qemu-kvm libvirt-daemon-system virtinst sshpass

# Fedora
sudo dnf install qemu-kvm libvirt virt-install sshpass
```

Ensure your user is in the `kvm` and `libvirt` groups:

```bash
sudo usermod -aG kvm,libvirt $(whoami)
# Log out and back in for changes to take effect
```

### CI/CD

Tests run automatically in GitHub Actions:
- **Daily schedule**: 6 AM UTC
- **On push**: Changes to main branch affecting core components
- **On PR**: When labeled with `e2e-test`
- **Manual**: Via workflow dispatch

## Running Tests

### Local Execution

1. **Build the ISO first**:

```bash
make build
bash scripts/generate-iso-simple.sh
```

2. **Run all tests**:

```bash
./tests/e2e/test_bootc_upgrade_rollback.sh
```

3. **Run with options**:

```bash
# Specify ISO path
./tests/e2e/test_bootc_upgrade_rollback.sh --iso /path/to/lifeos.iso

# Keep VM after test (for debugging)
./tests/e2e/test_bootc_upgrade_rollback.sh --no-cleanup

# Verbose output
./tests/e2e/test_bootc_upgrade_rollback.sh --verbose

# Custom VM name
./tests/e2e/test_bootc_upgrade_rollback.sh --vm-name my-test-vm
```

### CI/CD Execution

Tests automatically run when:
- Pushing to `main` branch (paths: `daemon/**`, `cli/**`, `image/**`)
- PR is labeled with `e2e-test`
- Daily schedule runs
- Manual trigger via GitHub UI

## Test Configuration

Edit `tests/e2e/bootc_test_config.yaml` to customize:

```yaml
vm:
  memory: "4096"    # VM RAM in MB
  cpus: "2"         # Number of CPUs
  disk_size: "20G"  # Disk size

network:
  ssh_port: "2222"  # Host SSH port
  
timeouts:
  vm_boot: "120"    # Boot timeout in seconds
```

## Test Cases

### 1. bootc status
- Verifies `bootc status` command works
- Checks for "booted" slot indicator
- Validates JSON output structure

### 2. bootc upgrade --check
- Tests update checking functionality
- Handles "no updates available" gracefully

### 3. bootc upgrade (dry-run)
- Tests upgrade simulation
- Skips if no updates available

### 4. bootc rollback
- Performs actual rollback operation
- Reboots VM to apply changes
- Verifies boot slot changed

### 5. life CLI commands
- Tests `life status`
- Tests `life update --dry`
- Tests `life rollback --dry`

### 6. System bootable
- Verifies system remains bootable after operations
- Checks basic system commands work
- Validates systemd is running

### 7. Daemon running
- Verifies `lifeosd` daemon is active
- Checks systemd service status

## Test Results

### Output Format

```
[INFO] Test: bootc status
✓ PASS: bootc status

[INFO] Test: bootc rollback
✓ PASS: bootc rollback - Successfully rolled back from A to B

=========================================
           TEST SUMMARY
=========================================
PASSED:  7
FAILED:  0
SKIPPED: 2
=========================================
ALL TESTS PASSED
```

### Result Types

- **PASS**: Test completed successfully
- **FAIL**: Test failed (check logs for details)
- **SKIP**: Test skipped (usually due to preconditions not met)

## Debugging

### View VM Console

If tests fail, check the VM console:

```bash
# Using virsh
virsh console lifeos-bootc-test

# Or check libvirt logs
sudo journalctl -u libvirtd -f
```

### Keep VM Running

Use `--no-cleanup` to inspect the VM after tests:

```bash
./tests/e2e/test_bootc_upgrade_rollback.sh --no-cleanup

# Then SSH into the VM
ssh -p 2222 lifeos@localhost
# Password: lifeos
```

### Manual Cleanup

```bash
# Destroy and remove VM
virsh destroy lifeos-bootc-test
virsh undefine lifeos-bootc-test --nvram

# Remove disk
sudo rm -f /var/lib/libvirt/images/lifeos-bootc-test.qcow2
```

### Check Logs

```bash
# Test logs are saved to /tmp
ls -la /tmp/bootc-test-*.log

# View specific log
cat /tmp/bootc-test-$(date +%Y%m%d).log
```

## Troubleshooting

### KVM Not Available

**Error**: `/dev/kvm not found`

**Solution**:
```bash
# Check if CPU supports virtualization
egrep -c '(vmx|svm)' /proc/cpuinfo

# Load KVM module
sudo modprobe kvm_intel  # Intel
sudo modprobe kvm_amd    # AMD
```

### SSH Connection Timeout

**Error**: `SSH did not become available`

**Solutions**:
1. Increase timeout in config: `timeouts.ssh_ready: "600"`
2. Check VM console: `virsh console lifeos-bootc-test`
3. Verify ISO boots correctly

### No Updates Available

**Error**: Tests skip with "No updates available"

**Solution**: This is expected when testing against the same version. The upgrade test will be skipped.

### Rollback Fails

**Error**: `No rollback slot available`

**Solution**: Rollback requires a previous deployment. Run an upgrade first, then rollback.

## CI/CD Artifacts

When tests run in CI, artifacts are uploaded:

- **bootc-test-logs-{sha}**: VM logs, console output
- **test-results-{sha}**: JUnit XML results, coverage reports
- **integration-test-logs-{sha}**: Integration test output

Download from the workflow run page in GitHub Actions.

## Performance

Typical test duration:
- **VM boot**: 30-60 seconds
- **SSH ready**: 60-120 seconds
- **Full test suite**: 5-10 minutes
- **Total CI time**: 15-20 minutes

## Contributing

When adding new E2E tests:

1. Add test function to `test_bootc_upgrade_rollback.sh`
2. Call test from `main()` function
3. Use `record_test()` for results
4. Update this README
5. Test locally before pushing

### Test Function Template

```bash
test_new_feature() {
    log_info "Test: New Feature"
    
    # Run test
    local output
    if ! output=$(ssh_execute "command to test"); then
        record_test "New Feature" "FAIL" "$output"
        return 1
    fi
    
    # Validate output
    if echo "$output" | grep -q "expected"; then
        record_test "New Feature" "PASS"
        return 0
    else
        record_test "New Feature" "FAIL" "Unexpected output"
        return 1
    fi
}
```

## Related

- [Bootc Documentation](https://github.com/containers/bootc)
- [LifeOS Architecture](../../docs/architecture.md)
- [Development Guide](../../AGENTS.md)
