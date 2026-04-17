# LifeOS Installation Guide

This guide covers installing LifeOS on bare metal or virtual machines.

LifeOS is an immutable, AI-native Linux distribution built on Fedora bootc. It ships with **COSMIC Desktop**, a modern Wayland-native desktop environment developed by System76 (the team behind Pop!\_OS), designed for speed, composability, and a clean user experience.

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Download](#download)
3. [Create Bootable Media](#create-bootable-media)
4. [Installation](#installation)
5. [Post-Installation](#post-installation)
6. [Security Defaults](#security-defaults)
7. [Troubleshooting](#troubleshooting)

## System Requirements

### Minimum Requirements

| Component | Minimum | Notes |
|-----------|---------|-------|
| CPU | 64-bit x86_64 | Intel or AMD, 2+ cores |
| RAM | 4 GB | 8 GB recommended |
| Storage | 40 GB | SSD strongly recommended |
| GPU | Any | Integrated graphics OK |
| Network | Internet | For updates and AI models |

### Recommended Specifications

| Component | Recommended | Notes |
|-----------|-------------|-------|
| CPU | 4+ cores | Modern Intel/AMD |
| RAM | 16 GB | For local AI models |
| Storage | 256 GB NVMe SSD | Fast boot and app launches |
| GPU | NVIDIA/AMD | For AI acceleration |
| Network | Broadband | 50+ Mbps for model downloads |

### Supported Hardware

#### Tested Laptops
- Dell XPS 13/15/17 (2019+)
- Lenovo ThinkPad T/X series
- Framework Laptop
- System76 laptops
- HP Spectre/Envy series

#### Tested Desktops
- Intel NUC (8th gen+)
- AMD Ryzen-based systems
- Custom builds with NVIDIA/AMD GPUs

See the [documentation index](../README.md) for the current hardware, operations, and release docs.

## Download

### Official Releases

Download the latest published install media from GitHub Releases:
- GitHub Releases: https://github.com/hectormr/lifeos/releases

### Verify Download

Always verify the SHA256 checksum that matches the exact release asset you downloaded:

```bash
# Example: latest release asset names vary by version
wget https://github.com/hectormr/lifeos/releases/download/<tag>/lifeos-<version>-x86_64.iso
wget https://github.com/hectormr/lifeos/releases/download/<tag>/lifeos-<version>-x86_64.iso.sha256

# Verify
sha256sum -c lifeos-<version>-x86_64.iso.sha256
```

## Create Bootable Media

### Linux/macOS

Using `dd` (command line):

```bash
# Identify your USB drive (be careful!)
lsblk

# Example: /dev/sdb (replace with your device)
sudo dd if=lifeos-0.1.0-x86_64.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

Using `balenaEtcher` (GUI):
1. Download and install [balenaEtcher](https://www.balena.io/etcher/)
2. Select the LifeOS ISO
3. Select your USB drive
4. Flash!

### Windows

Using Rufus:
1. Download [Rufus](https://rufus.ie/)
2. Insert USB drive (8GB+)
3. Select LifeOS ISO
4. Partition scheme: GPT
5. Target system: UEFI
6. Click Start

## Installation

### 1. Boot from USB

1. Insert the bootable USB drive
2. Restart your computer
3. Enter boot menu (usually F12, F10, or Esc)
4. Select USB drive
5. Choose "Install LifeOS"

### 2. Installation Options

#### Graphical Install (Recommended)

The guided installer will:
1. Detect your hardware
2. Ask you to select the destination disk explicitly
3. Set up disk partitions
4. Install the base system
5. Configure user account
6. Install bootloader

By default, the generated Phase 2 ISO uses interactive installer mode to avoid automatic disk wipes.
For automated lab/CI installs only, build the ISO with:

```bash
LIFEOS_INSTALL_MODE=unattended sudo bash scripts/generate-iso-simple.sh --type iso
```

`unattended` mode can repartition disks automatically.

#### Advanced Options

Press `Tab` at the boot menu to add kernel parameters:

```
# Disable secure boot workaround
inst.nosb

# Disable GUI (text mode)
inst.text
```

### 3. Disk Partitioning

#### Automatic (Recommended)

The installer will create:
- `/boot` - 1 GB (EFI + boot files)
- `/boot/efi` - 512 MB (EFI System Partition)
- `/` - Remaining space (managed by bootc — uses composefs for the immutable OS root; user data lives on BTRFS or EXT4)

#### Manual Partitioning

For advanced users, manual partitioning supports:
- BTRFS (recommended for user data — enables snapshots)
- LVM + EXT4
- Encryption (LUKS)

> **Note:** The OS root (`/usr`) is immutable and managed by bootc via composefs. You don't choose a filesystem for it — bootc handles this automatically. Your choice of BTRFS/EXT4 applies to `/home` and `/var` partitions.
- Dual boot

### 4. User Setup

During installation, you'll create:
- Username
- Password
- Computer name

The first user is automatically added to the `wheel` group (sudo access).

### 5. First Boot

After installation:
1. Remove USB drive
2. System reboots automatically
3. First-boot wizard runs
4. AI model download (optional)
5. Desktop appears

## Post-Installation

### Initial Setup

Run the first-boot wizard:

```bash
# Or manually trigger
life first-boot
```

This will:
- Configure timezone
- Set up update preferences
- Download AI models (optional)
- Configure privacy settings

### Update System

```bash
# Inspect local preference and real bootc state
life update status
sudo bootc status

# Check whether a newer deployment exists
sudo bootc upgrade --check

# Stage the next deployment for the next reboot
life update
# Equivalent low-level command:
sudo bootc upgrade

# Reboot when you are ready to boot into the staged deployment
sudo reboot
```

Canonical rule: the installed/staged OS version is whatever `bootc status`
reports for the tracked GHCR image. `lifeos.toml` only stores preference such as
the desired channel.

### Install Additional Software

```bash
# Using the LifeOS Store
life store install flathub:com.spotify.Client

# Using flatpak directly
flatpak install flathub com.visualstudio.code

# Using the AI assistant
life ai do "install video editing software"
```

LifeOS developer images already include the native baseline needed to build this repo on-host:

```bash
cargo --version
rustc --version
rustfmt --version
cargo clippy --version
cargo audit --version
pkg-config --modversion gtk4
```

#### Bun runtime (pre-installed)

LifeOS ships **Bun** (JS/TS runtime + package manager, v1.x) directly on the host image at `/usr/local/bin/bun`, con un symlink `bunx` junto a él. Está pre-instalado porque los plugins de **Claude Code Channels** — incluido el plugin de Telegram — lo requieren para ejecutar sus servidores locales. No tocás Bun como usuario final; está ahí para que las integraciones de Axi funcionen sin pasos extra.

```bash
bun --version
```

Use `toolbox` for extra development stacks that should stay isolated from the host, such as Node.js:

```bash
# Example: isolated Node.js environment
toolbox create dev-node
toolbox enter dev-node
sudo dnf install -y nodejs npm
```

Leave the toolbox with:

```bash
exit
```

### Enable GPU Acceleration

#### NVIDIA

```bash
# Check if NVIDIA drivers are installed
nvidia-smi

# Check Secure Boot + module signing/enrollment state
sudo lifeos-nvidia-secureboot.sh status

# If key enrollment is pending:
sudo lifeos-nvidia-secureboot.sh enroll
sudo reboot
```

On image-mode/bootc hosts, avoid relying on runtime `akmods` installs on read-only `/usr`.
Prefer updating to an image that already contains signed NVIDIA modules.
See [`../operations/nvidia-secure-boot.md`](../operations/nvidia-secure-boot.md) for the full build + enrollment flow.
Current release images also include bootc kargs to prefer proprietary NVIDIA over `nouveau`
(`rd.driver.blacklist=nouveau`, `modprobe.blacklist=nouveau`, `nouveau.modeset=0`).

#### AMD

AMD GPUs work out of the box with Mesa drivers.

### Configure AI Models

```bash
# Start AI service
life ai start

# Pull recommended models
life ai pull qwen3.5-4b

# Check status
life ai status --verbose
```

## Security Defaults

LifeOS ships with security hardening enabled out of the box — no manual setup required.

| Feature | Details |
|---------|---------|
| **Sysctl hardening** | CIS Benchmark Level 1 kernel parameters applied at boot |
| **firewalld** | Custom `lifeos` zone active by default; only essential ports open |
| **auditd** | System call auditing enabled; logs at `/var/log/audit/` |
| **DNS-over-TLS** | systemd-resolved configured with Quad9 (`9.9.9.9`) and Cloudflare (`1.1.1.1`) as upstream resolvers |

These defaults are baked into the OS image and survive updates. You can review or adjust firewall rules with:

```bash
sudo firewall-cmd --list-all --zone=lifeos
```

### Sudoers NOPASSWD Policy

LifeOS uses a least-privilege sudoers drop-in at `/etc/sudoers.d/lifeos-axi`. Only explicit, narrowly scoped commands are allowed without a password prompt — never a blanket `ALL` rule. Entries relevant to the AI-driven self-deploy workflow:

| Command | Purpose |
|---------|---------|
| `/usr/local/bin/lifeos-dev-deploy.sh *` | Deploy daemon/CLI binaries and unit files from the repo onto the live system (validated paths only) |
| `/usr/bin/udevadm control --reload` | Re-apply udev rules after `lifeos-dev-deploy.sh` syncs a new rules file |
| `/usr/bin/udevadm trigger --subsystem-match=cpu *` | Re-trigger CPU subsystem events (e.g. after thermal rule updates), wildcard constrained to the `--action=` suffix |

All three are wheel-group only and audited by `auditd`. See the canonical list and rationale in `image/files/etc/sudoers.d/lifeos-axi`.

## Troubleshooting

### Installation Issues

#### "No bootable device found"
- Ensure UEFI mode is enabled in BIOS
- Disable Secure Boot (or add custom keys)
- Try different USB port

#### Black screen during boot
- Add kernel parameter: `nomodeset`
- For NVIDIA: `nouveau.modeset=0`
- Try text mode: `inst.text`

#### Installation freezes
- Check RAM with memtest86+
- Try minimal install: `inst.minimal`
- Disable Wi-Fi during install

### Post-Install Issues

#### No Wi-Fi
```bash
# Check if Wi-Fi is blocked
rfkill list
rfkill unblock wifi

# Check NetworkManager
systemctl status NetworkManager
```

#### No sound
```bash
# Check audio devices
pactl list short sinks

# Select default sink
pactl set-default-sink <name>

# Restart pipewire
systemctl --user restart pipewire
```

#### High CPU/Memory usage
```bash
# Check resource usage
top

# Check AI service
life ai status

# Stop AI if needed
life ai stop
```

#### Boot problems
```bash
# From recovery mode
life recover

# Rollback to previous version
life rollback
```

### Getting Help

1. Review the [documentation index](../README.md)
2. Search [GitHub Issues](https://github.com/hectormr/lifeos/issues)
3. Check the relevant operations runbook under `docs/operations/`
4. File a bug report: `life feedback bug`

## Advanced Topics

### Dual Boot with Windows

1. Disable Fast Startup in Windows
2. Shrink Windows partition
3. Install LifeOS in free space
4. Use systemd-boot or GRUB

### Disk Encryption

During install, select "Encrypt disk":
- Uses LUKS2 encryption
- Prompts for password at boot
- Can use TPM2 for automatic unlock

### Remote Installation

For headless servers:

```bash
# Enable SSH in installer
inst.sshd

# Connect from another machine
ssh root@<installer-ip>
# Run: lifeos-installer
```

## See Also

- [../README.md](../README.md) - Documentation index
- [../operations/nvidia-secure-boot.md](../operations/nvidia-secure-boot.md) - NVIDIA + Secure Boot flow
- [../../README.md](../../README.md) - Project overview
