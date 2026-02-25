# Beta Testing Guide

Complete guide for LifeOS beta testers.

## Overview

This guide covers:
- Testing methodologies
- Reporting procedures
- Testing schedules
- Communication channels

## Testing Methodologies

### Smoke Testing

Quick verification that basic functions work:

```bash
# Installation smoke test
checklist() {
    echo "□ System boots"
    echo "□ Desktop loads"
    echo "□ Network connects"
    echo "□ Updates work"
    echo "□ AI service starts"
    echo "□ Apps install"
}
```

### Regression Testing

Verify existing features still work after changes:

| Feature | Test Steps | Expected Result |
|---------|------------|-----------------|
| Update | `life update apply` | System updates |
| Rollback | `life rollback` | Returns to previous |
| Recovery | `life recover` | Fixes boot issues |
| AI Chat | `life ai chat` | Interactive session |

### Exploratory Testing

Try unconventional use cases:
- Unusual hardware combinations
- Stress testing (many apps open)
- Edge cases (very long uptime)
- Security testing

### Compatibility Testing

Test on different hardware:
- Various GPU vendors
- Different Wi-Fi chipsets
- Multiple display setups
- Peripherals (printers, scanners)

## Test Plans

### Installation Testing

#### Fresh Install
1. Download ISO
2. Verify checksum
3. Create bootable USB
4. Boot and install
5. Complete first-boot wizard
6. Verify all services start

#### Upgrade Testing
1. Install previous stable
2. Switch to beta channel
3. Apply beta update
4. Verify data preserved
5. Test all features

### Feature Testing

#### AI Features

```bash
# Test model management
life ai pull qwen3:8b
life ai models
life ai remove qwen3:8b

# Test chat
life ai chat
# Try: math problems, coding, creative writing

# Test voice (if available)
life ai voice "what time is it"

# Test screen understanding
life ai see --screen "what's on my desktop"

# Test natural language actions
life ai do "take a screenshot"
```

#### System Management

```bash
# Test updates
life update check
life update apply --dry-run
life update apply

# Test rollback
life rollback

# Test recovery
life recover health
life recover boot

# Test capsule (backup/restore)
life capsule export /tmp/backup.tar.gz
life capsule import /tmp/backup.tar.gz
```

#### App Store

```bash
# Browse apps
life store search browser
life store categories

# Install/remove
life store install flathub:org.mozilla.firefox
life store remove org.mozilla.firefox

# Updates
life store update
```

### Performance Testing

#### Boot Time
```bash
# Measure boot time
systemd-analyze
systemd-analyze blame
systemd-analyze critical-chain
```

#### Resource Usage
```bash
# Idle usage
top -b -n 1 | head -20

# Memory after boot
free -h

# Disk usage
df -h
```

#### AI Performance
```bash
# Benchmark model inference
life ai benchmark qwen3:8b

# Monitor GPU usage
nvidia-smi  # NVIDIA
rocm-smi    # AMD
```

## Reporting Procedures

### Bug Report Quality

**Good bug report:**
1. Specific and reproducible
2. Includes system info
3. Has clear steps
4. Shows expected vs actual
5. Includes logs

**Example:**
```
Title: AI chat freezes when asking long questions

Steps:
1. Start AI: life ai start
2. Open chat: life ai chat
3. Paste 1000+ character prompt

Expected: Response streams normally
Actual: UI freezes for 30+ seconds

System: LifeOS 0.2.0-beta.1, 16GB RAM, GTX 1060
Logs: [attached journalctl output]
```

### Severity Classification

| Severity | Criteria | Response Time |
|----------|----------|---------------|
| Critical | Data loss, security, system unbootable | 24 hours |
| High | Major feature broken | 3 days |
| Medium | Feature partially broken | 1 week |
| Low | Cosmetic/minor | Next release |

### Feedback Collection

#### Daily Journal
Keep notes on:
- What you tested
- What worked
- What didn't
- Ideas for improvement

#### Weekly Reports
Submit via:
```bash
life beta report --weekly
```

Include:
- Bugs found (with IDs)
- Features tested
- Performance observations
- General feedback

## Communication

### Discord Channels

| Channel | Purpose |
|---------|---------|
| #announcements | Official updates |
| #general | General discussion |
| #bug-reports | Bug hunting |
| #feature-discussion | Ideas and feedback |
| #testing | Test coordination |
| #help | Questions and support |
| #off-topic | Casual chat |

### Meeting Schedule

| Meeting | When | Description |
|---------|------|-------------|
| Weekly Standup | Mondays 18:00 UTC | Progress update |
| Bug Triage | Wednesdays 18:00 UTC | Review new bugs |
| Feature Review | Fridays 18:00 UTC | Discuss proposals |

### Email Updates

Weekly digest includes:
- New beta builds
- Fixed issues
- Testing priorities
- Tips and tricks

## Testing Checklists

### Pre-Release Checklist

```markdown
## System Tests
- [ ] Fresh install works
- [ ] Upgrade from previous works
- [ ] Rollback works
- [ ] Recovery mode works

## Desktop Tests
- [ ] Login/logout
- [ ] Lock/unlock
- [ ] Suspend/resume
- [ ] Shutdown/reboot
- [ ] Display configuration
- [ ] Audio input/output
- [ ] Network (Wi-Fi/Ethernet)
- [ ] Bluetooth

## AI Tests
- [ ] Start/stop service
- [ ] Pull models
- [ ] Chat interface
- [ ] Voice commands (if applicable)
- [ ] Screen understanding
- [ ] Natural language actions

## App Tests
- [ ] Flatpak apps install
- [ ] Store browse/search
- [ ] Updates work
- [ ] System apps work

## Edge Cases
- [ ] Long uptime (24h+)
- [ ] Many apps open
- [ ] Full disk scenario
- [ ] Network disconnect/reconnect
- [ ] Low battery (laptops)
```

## Tools and Resources

### Built-in Tools

```bash
# System diagnostics
life system diagnose
life system diagnose --full

# Hardware info
life system hardware

# Performance metrics
life status resources

# Log collection
life system logs --export
```

### External Tools

- **stress-ng**: System stress testing
- **phoronix-test-suite**: Benchmarking
- **memtest86+**: Memory testing
- **smartmontools**: Disk health

## Best Practices

### DO
- ✅ Test on dedicated hardware/VM
- ✅ Backup data regularly
- ✅ Document everything
- ✅ Ask questions
- ✅ Help other testers
- ✅ Update frequently

### DON'T
- ❌ Use beta on production machine
- ❌ Ignore data loss warnings
- ❌ Test without backups
- ❌ File duplicate bugs
- ❌ Share beta builds publicly
- ❌ Ignore security updates

## Rewards Program

### Points System

| Action | Points |
|--------|--------|
| File verified bug | 10 points |
| File quality bug | 25 points |
| Submit feature request (accepted) | 15 points |
| Complete test case | 5 points |
| Help other tester | 5 points |
| Write documentation | 30 points |
| Submit PR | 50 points |

### Redemption

| Reward | Points |
|--------|--------|
| Beta Tester sticker | 50 |
| T-shirt | 150 |
| Hoodie | 300 |
| Conference ticket | 500 |
| Lifetime Pro license | 1000 |

## Appendix

### Common Commands

```bash
# Beta management
life beta status
life beta update
life beta rollback
life beta leave

# Feedback
life feedback bug
life feedback feature
life feedback praise

# System
life system info
life system diagnose
life system logs
```

### Quick Links

- [Issue Tracker](https://github.com/hectormr/lifeos/issues)
- [Test Cases](https://lifeos.io/beta/tests)
- [Documentation](https://docs.lifeos.io)
- [Discord](https://discord.gg/lifeos-beta)

---

Thank you for making LifeOS better! 🚀
