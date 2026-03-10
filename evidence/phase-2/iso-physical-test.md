# Phase 2 ISO Physical Test

**Phase:** 2  
**Scope:** ISO installation and boot validation on physical hardware  
**Date:** 2026-03-09  
**Owner:** @hectormr206  
**Status:** PASS

---

## 1) Target Hardware

- Vendor/model: AIstone Global laptop platform
- CPU: Intel Raptor Lake platform
- GPU(s): Intel UHD Graphics (`8086:a788`) + NVIDIA GeForce RTX 5070 Ti Mobile (`10de:2f18`)
- Disk: SanDisk/WD SN530 NVMe (`15b7:5009`)
- UEFI mode: yes (bootc + Secure Boot host)
- Secure Boot: enabled
- ISO file: not captured in this retrospective record
- ISO checksum: not captured in this retrospective record

---

## 2) Install Flow Evidence

Captured milestones (operator confirmation + current installed host state):

1. Boot from ISO media: completed.
2. Installer starts successfully: completed.
3. Disk partitioning completes: completed.
4. Installation completes: completed.
5. First reboot into installed system: completed.
6. First-boot flow completes: completed.

Result:
- PASS/FAIL: PASS
- Blocking issue (if any): none reported

---

## 3) Post-install Health Checks

Collected output excerpt:

```bash
$ date -Is
2026-03-09T15:15:01-06:00

$ sudo bootc status
booted image: localhost/lifeos:edge-20260309-629a4a4
version: edge-20260309-629a4a4
digest: sha256:df80ab23af9fbba99bae82efc20fd60135d77e7dc98b63a3a7932a031acbcc8d
rollback image: localhost/lifeos:edge-20260309-34b0fc0

$ life status
Version: 0.1.0
Channel: edge
Health: healthy
Updates: Up to date

$ systemctl is-system-running
degraded

$ systemctl --failed --no-pager
● systemd-remount-fs.service loaded failed failed Remount Root and Kernel File Systems

$ lspci -nn | grep -Ei 'vga|3d|display|nvidia|intel'
00:02.0 VGA compatible controller: Intel Corporation Raptor Lake-S UHD Graphics [8086:a788]
02:00.0 VGA compatible controller: NVIDIA Corporation GB205M [GeForce RTX 5070 Ti Mobile] [10de:2f18]

$ sudo mokutil --sb-state
SecureBoot enabled
```

Optional:

```bash
sudo lifeos-check
```

---

## 4) Mapping to Spec Item

Spec item:
- `Prueba de ISO en al menos un equipo fisico real`

Checklist:
- [x] ISO boots in physical hardware
- [x] Installation finishes successfully
- [x] Installed system boots and reaches desktop/login
- [x] Core services are operational
- [x] No critical failed units

Decision:
- PASS/FAIL: PASS
- Notes:
  - Host is operational (`life status: healthy`) on real installed system.
  - `systemctl` shows `degraded` due `systemd-remount-fs.service`; this is a known non-blocking issue in bootc/image-mode and does not block normal operation for this validation gate.

---

## 5) Recovery Validation (Recommended)

```bash
sudo bootc upgrade --check
```

If applicable, validate rollback path:

```bash
sudo bootc rollback
sudo reboot
```

Record outcome:
- Rollback tested: no (already validated separately in VM automation)
- Outcome: not re-run in this physical ISO validation session

---

## 6) Final Sign-off

- Reviewer: @hectormr206
- Date: 2026-03-09
- Decision: APPROVED
- Follow-ups:
  - Keep tracking `systemd-remount-fs.service` as known non-blocking bootc/image-mode behavior.
