# LifeOS Installation Guide

This guide covers installing LifeOS on bare metal or virtual machines.

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Download](#download)
3. [Create Bootable Media](#create-bootable-media)
4. [Installation](#installation)
5. [Post-Installation](#post-installation)
6. [Troubleshooting](#troubleshooting)

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

See [HARDWARE_COMPATIBILITY.md](./HARDWARE_COMPATIBILITY.md) for detailed compatibility info.

## Download

### Official Releases

Download the latest ISO from:
- GitHub Releases: https://github.com/hectormr/lifeos/releases
- Official mirror: https://lifeos.io/download

### Verify Download

Always verify the SHA256 checksum:

```bash
# Download ISO and checksum
wget https://github.com/hectormr/lifeos/releases/download/v0.1.0/lifeos-0.1.0-x86_64.iso
wget https://github.com/hectormr/lifeos/releases/download/v0.1.0/lifeos-0.1.0-x86_64.iso.sha256

# Verify
sha256sum -c lifeos-0.1.0-x86_64.iso.sha256
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
3. Set up disk partitions (BTRFS)
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
- `/` - Remaining space (BTRFS with subvolumes)

#### Manual Partitioning

For advanced users, manual partitioning supports:
- BTRFS (recommended)
- LVM + EXT4
- Encryption (LUKS)
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
- Set up automatic updates
- Download AI models (optional)
- Configure privacy settings

### Update System

```bash
# Check for updates
life update check

# Apply updates
life update apply

# Or use GNOME Software
```

### Install Additional Software

```bash
# Using the LifeOS Store
life store install flathub:com.spotify.Client

# Using flatpak directly
flatpak install flathub com.visualstudio.code

# Using the AI assistant
life ai do "install video editing software"
```

For development stacks on the immutable host, use `toolbox`:

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

# If not, install from Software app or:
sudo akmods --force
sudo dracut --force
```

#### AMD

AMD GPUs work out of the box with Mesa drivers.

### Configure AI Models

```bash
# Start AI service
life ai start

# Pull recommended models
life ai pull qwen3:8b

# Check status
life ai status --verbose
```

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
life status resources

# Check AI service
life ai status

# Stop AI if needed
life ai stop
```

#### Boot problems
```bash
# From recovery mode
life recover boot

# Rollback to previous version
life rollback
```

### Getting Help

1. Check [HARDWARE_COMPATIBILITY.md](./HARDWARE_COMPATIBILITY.md)
2. Search [GitHub Issues](https://github.com/hectormr/lifeos/issues)
3. Join [Discord Community](https://discord.gg/lifeos)
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

- [HARDWARE_COMPATIBILITY.md](./HARDWARE_COMPATIBILITY.md) - Detailed hardware support
- [BETA_TESTING.md](./BETA_TESTING.md) - Join the beta program
- [README.md](../README.md) - Project overview
