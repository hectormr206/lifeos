# Phase 2 Hardware Validation

**Phase:** 2  
**Scope:** Real hardware validation for GPU hybrid support and gaming path  
**Date:** 2026-03-09  
**Owner:** @hectormr206  
**Status:** PASS (GPU + Steam/Proton + high-refresh/VRR validated)

---

## 1) Test Environment

- Device model: AIstone Global laptop platform (subsystem `1d05:604e`)
- CPU: Intel Raptor Lake-S (from PCI ID for iGPU host bridge path)
- iGPU: Intel Corporation Raptor Lake-S UHD Graphics (rev 04)
- dGPU: NVIDIA GB205M GeForce RTX 5070 Ti Mobile (`10de:2f18`)
- RAM: not captured in this record
- Display(s): internal panel active on NVIDIA (`Disp.A On` in `nvidia-smi`)
- Firmware/BIOS version: not captured in this record
- Secure Boot: enabled
- LifeOS image tag: edge channel (exact tag used during successful NVIDIA validation)
- LifeOS image digest: previously validated on signed edge digest path
- Kernel: `6.18.16-200.fc43.x86_64`

---

## 2) Command Evidence (Raw Output)

Collected outputs (session excerpts):

```bash
$ sudo lifeos-nvidia-secureboot.sh status
LifeOS NVIDIA Secure Boot status
  Kernel: 6.18.16-200.fc43.x86_64
  Secure Boot: enabled
  NVIDIA GPU: detected
  nvidia.ko signer: LifeOS NVIDIA Kmod Secure Boot
  LifeOS MOK cert: present (/usr/share/lifeos/secureboot/lifeos-nvidia-kmod.der)
  LifeOS MOK cert: enrolled

$ lspci -nnk -s 02:00.0
02:00.0 VGA compatible controller [0300]: NVIDIA Corporation GB205M [GeForce RTX 5070 Ti Mobile] [10de:2f18] (rev a1)
  Kernel driver in use: nvidia
  Kernel modules: nouveau, nvidia_drm, nvidia

$ lsmod | grep -E '^nvidia|^nouveau' || true
nvidia_uvm ...
nvidia_drm ...
nvidia_modeset ...
nvidia ...

$ nvidia-smi
NVIDIA-SMI 580.126.18   Driver Version: 580.126.18   CUDA Version: 13.0
GPU 0: NVIDIA GeForce RTX 5070 Ti Mobile
```

```bash
$ cat /proc/cmdline
... rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nouveau.modeset=0 nvidia-drm.modeset=1
```

---

## 3) Acceptance for `GPU hybrid support` item

Map to spec item:
- `Soporte GPU hibrida (Nvidia Optimus/PRIME), drivers akmod-nvidia via bootc`

Checklist:
- [x] NVIDIA proprietary driver active (`Kernel driver in use: nvidia`)
- [x] Secure Boot path valid (signed module + enrolled key)
- [x] `nvidia-smi` functional after reboot
- [x] Hybrid topology detected (iGPU + dGPU)
- [x] No fallback to `nouveau` in normal boot

Result:
- PASS/FAIL: PASS
- Notes:
  - Resolved sequence captured in debugging:
    1) signed NVIDIA module shipped in image
    2) MOK certificate enrolled and loaded by kernel (`Loaded X.509 cert 'LifeOS NVIDIA Kmod Secure Boot'`)
    3) kernel args enforce proprietary preference and avoid nouveau binding first

---

## 4) Acceptance for `Steam/Proton + display` item

Map to spec item:
- `Steam RPM (default) + Proton, displays 144Hz+, G-Sync/Adaptive-Sync`

Commands:

```bash
rpm -q steam steam-devices

$ rpm -q steam steam-devices
steam-1.0.0.85-2.fc43.i686
steam-devices-1.0.0.101^git20260123.e0ab314-7.fc43.noarch
```

```bash
$ nvidia-smi
Mon Mar  9 15:05:22 2026
NVIDIA-SMI 580.126.18   Driver Version: 580.126.18   CUDA Version: 13.0
GPU 0: NVIDIA GeForce RTX 5070 Ti Mobile
Memory-Usage: 5056MiB / 12227MiB
Processes:
  ... RE2.exe 4873MiB
```

Runtime evidence (session screenshots):
- Steam library shows `Resident Evil 2` downloaded and runnable with Proton components installed (`Proton Experimental`, `Steam Linux Runtime 3.0`, `Steamworks Common Redistributables`).
- Game launch menu and in-game scene captured successfully under Proton.
- In-game overlay metrics observed:
  - Menu capture: `FPS 121` (min/max shown in overlay `86/184`)
  - Gameplay capture: `FPS 72` (min/max shown in overlay `33/117`)
  - GPU utilization observed in-session (`~33%` to `~47%`)
  - GPU VRAM observed in overlay (`~4.1 GiB` to `~5.4 GiB`) and `nvidia-smi` (~5.0 GiB in use)
- Display settings capture (COSMIC):
  - Internal panel resolution: `2560x1600`
  - Refresh rate: `240 Hz`
  - Variable refresh rate: `Automatico` (VRR enabled/automatic mode)

Validation checklist:
- [x] Steam packages installed (`rpm -q steam steam-devices`)
- [x] Steam launches correctly
- [x] Proton selectable in Steam compatibility settings
- [x] At least one Proton title launches
- [x] High refresh mode(s) detected (>=120Hz where supported)
- [x] Adaptive sync behavior documented (if hardware supports it)

Result:
- PASS/FAIL: PASS
- Notes:
  - Steam + Proton gaming path is validated on real hardware (NVIDIA active and game process visible in `nvidia-smi`).
  - Display validation confirms high-refresh operation (`240 Hz`) and VRR configured in automatic mode.

---

## 5) Incidents and Fixes

| ID | Symptom | Root Cause | Fix | Permanent? |
|----|---------|------------|-----|------------|
| 1 | `modprobe nvidia`: `Key was rejected by service` | Image/cert state mismatch during early runs with Secure Boot | Publish signed image + enroll MOK + reboot | Yes |
| 2 | `modprobe nvidia`: `No such device` with signed module | `nouveau` grabbed dGPU first on boot | Add bootc kargs: blacklist `nouveau`, enable `nvidia-drm.modeset=1` | Yes |

---

## 6) Final Sign-off

- Reviewer: pending
- Date: pending
- Decision: APPROVED (GPU hybrid + Steam/Proton + display sync checks passed)
- Follow-ups:
  - Capture exact `bootc status` tag+digest for this evidence record.
