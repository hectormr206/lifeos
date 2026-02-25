---
name: Bug report
about: Create a report to help us improve LifeOS
title: '[BUG] '
labels: bug, needs-triage
assignees: ''

---

## Bug Description
<!-- A clear and concise description of what the bug is -->

## Steps to Reproduce
<!-- Provide detailed steps to reproduce the behavior -->
1. 
2. 
3. 
4. 

## Expected Behavior
<!-- What did you expect to happen? -->

## Actual Behavior
<!-- What actually happened? -->

## Screenshots
<!-- If applicable, add screenshots to help explain the problem -->

## Environment

<!-- Run `life system info` and paste the output here -->
```
LifeOS Version: 
Kernel Version: 
Desktop Environment: 
Installation Type: 
```

## System Information

### Hardware
- **Device**: <!-- e.g., Dell XPS 13 9300 -->
- **CPU**: <!-- e.g., Intel Core i7-1065G7 -->
- **RAM**: <!-- e.g., 16 GB -->
- **GPU**: <!-- e.g., Intel Iris Plus Graphics -->
- **Storage**: <!-- e.g., 512GB NVMe SSD -->

### Software
- **LifeOS Version**: <!-- e.g., 0.1.0-beta.2 -->
- **Kernel**: <!-- e.g., 6.7.5-200.fc39.x86_64 -->
- **Desktop**: <!-- GNOME 45 / COSMIC -->
- **Session Type**: <!-- Wayland / X11 -->

## Logs and Diagnostics

<!-- Attach relevant logs -->
```bash
# System logs
journalctl -b --priority=3 --no-pager > system-logs.txt

# Application logs
# (specify which application)

# Crash reports
ls -la /var/lib/lifeos/crashes/
```

## Additional Context

<!-- Add any other context about the problem -->
- Does this happen consistently or intermittently?
- Did this work in a previous version?
- Any workarounds you've discovered?
- Related issues or PRs?

## Severity

<!-- Please select one -->
- [ ] 🔴 Critical - System crash, data loss, security vulnerability
- [ ] 🟠 High - Major feature broken, significant impact
- [ ] 🟡 Medium - Feature partially broken, workaround exists
- [ ] 🟢 Low - Minor issue, cosmetic, or enhancement

## Checklist

<!-- Please check all that apply -->
- [ ] I've searched existing issues to avoid duplicates
- [ ] I've tested on the latest beta/RC version
- [ ] I've provided all requested information
- [ ] I've attached relevant logs and screenshots
- [ ] I can reproduce this issue consistently

## Beta Tester Info (if applicable)

- **Beta ID**: <!-- Your beta tester ID -->
- **Testing Focus Area**: <!-- AI / Desktop / System / Other -->
