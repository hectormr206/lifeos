# LifeOS Hardware Compatibility

This document lists hardware compatibility status for LifeOS.

## Compatibility Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Fully supported - works out of the box |
| ⚠️ | Partial support - may need manual configuration |
| ❌ | Not supported - known issues |
| 🧪 | Testing in progress |
| ❓ | Unknown/Not tested |

## Laptops

### Dell

| Model | Status | Notes |
|-------|--------|-------|
| XPS 13 (9300-9340) | ✅ | Excellent support, fingerprint reader works |
| XPS 15 (9500-9530) | ✅ | NVIDIA GPU may need proprietary drivers |
| XPS 17 (9700-9730) | ✅ | Similar to XPS 15 |
| Latitude 54xx/74xx | ✅ | Business line, fully compatible |
| Inspiron 15/16 | ⚠️ | Wi-Fi may need firmware update |

### Lenovo

| Model | Status | Notes |
|-------|--------|-------|
| ThinkPad T14/T14s | ✅ | All features work including fingerprint |
| ThinkPad X1 Carbon (Gen 8+) | ✅ | Excellent Linux support |
| ThinkPad P1 Gen 4+ | ✅ | NVIDIA Quadro supported |
| ThinkPad X13 | ✅ | Compact and fully functional |
| Yoga series | ⚠️ | Tablet mode may need configuration |
| Legion series | ⚠️ | Gaming features may need tweaks |

### HP

| Model | Status | Notes |
|-------|--------|-------|
| Spectre x360 | ✅ | Convertible features work |
| Envy 13/15 | ✅ | Good overall support |
| EliteBook series | ✅ | Business features supported |
| Pavilion | ❓ | Consumer line, varies by model |

### Framework

| Model | Status | Notes |
|-------|--------|-------|
| Framework 13 (Intel) | ✅ | Excellent open hardware support |
| Framework 13 (AMD) | ✅ | Ryzen models well supported |
| Framework 16 | 🧪 | Testing in progress |

### System76

| Model | Status | Notes |
|-------|--------|-------|
| All models | ✅ | Designed for Linux |
| Thelio desktops | ✅ | Full support |
| Pangolin | ✅ | AMD Ryzen, great value |

### ASUS

| Model | Status | Notes |
|-------|--------|-------|
| ZenBook series | ✅ | Generally well supported |
| VivoBook series | ⚠️ | Some models need Wi-Fi firmware |
| ROG Zephyrus | ⚠️ | Gaming features need configuration |
| ROG Strix | ⚠️ | RGB and gaming features |
| ProArt | ✅ | Creator-focused, good support |

### Apple (Apple Silicon)

| Model | Status | Notes |
|-------|--------|-------|
| MacBook Air M1/M2 | ❌ | Not supported (ARM64 different) |
| MacBook Pro M1/M2/M3 | ❌ | Asahi Linux is separate project |

## Desktop Components

### CPUs

| Vendor | Model | Status | Notes |
|--------|-------|--------|-------|
| Intel | Core i3/i5/i7/i9 (8th gen+) | ✅ | Full support |
| Intel | Core Ultra (Meteor Lake) | ✅ | NPU support via Intel OpenVINO |
| Intel | Xeon E/W series | ✅ | Server/workstation support |
| AMD | Ryzen 3/5/7/9 (2000+) | ✅ | Full support |
| AMD | Threadripper | ✅ | High core count support |
| AMD | EPYC | ✅ | Server support |

### GPUs

#### NVIDIA

| Model | Status | Notes |
|-------|--------|-------|
| RTX 40 series | ✅ | Proprietary drivers recommended |
| RTX 30 series | ✅ | Excellent support |
| RTX 20 series | ✅ | Full support |
| GTX 16 series | ✅ | Good support |
| GTX 10 series | ✅ | Legacy but supported |
| Tesla/Quadro | ✅ | Professional cards work well |

**Note:** Nouveau (open source) drivers provide basic support but proprietary drivers are recommended for full performance.

#### AMD

| Model | Status | Notes |
|-------|--------|-------|
| RX 7000 series | ✅ | Mesa drivers, full support |
| RX 6000 series | ✅ | Excellent support |
| RX 5000 series | ✅ | Full support |
| RX Vega series | ✅ | Good support |
| RX 500/400 series | ✅ | Legacy but functional |
| Instinct (MI series) | ✅ | ROCm support available |

#### Intel

| Model | Status | Notes |
|-------|--------|-------|
| Arc (A770, A750, etc.) | ✅ | Mesa drivers |
| Xe (11th-14th gen) | ✅ | Integrated graphics |
| UHD/Iris | ✅ | Older integrated graphics |

### Network Controllers

#### Wi-Fi

| Vendor | Chipset | Status | Notes |
|--------|---------|--------|-------|
| Intel | AX200/AX201/AX210 | ✅ | Best support |
| Intel | AX411/BE200 | ✅ | Wi-Fi 6E/7 |
| MediaTek | MT7921/MT7922 | ✅ | Good support |
| Realtek | RTL8821/RTL8822 | ✅ | May need firmware |
| Broadcom | BCM43xx | ⚠️ | Limited support |

#### Ethernet

| Vendor | Chipset | Status | Notes |
|--------|---------|--------|-------|
| Intel | I219/I225/I226 | ✅ | Excellent |
| Realtek | RTL8111/RTL8125 | ✅ | Common, well supported |
| Aquantia/Marvell | AQC107/AQC113 | ✅ | 10GbE support |
| Broadcom | BCM5719/BCM5720 | ✅ | Server-grade |

### Storage

| Type | Status | Notes |
|------|--------|-------|
| NVMe SSD | ✅ | Full TRIM and power management |
| SATA SSD | ✅ | Excellent support |
| SATA HDD | ✅ | Standard support |
| Intel Optane | ✅ | Works as NVMe |
| RAID (Intel) | ⚠️ | Use mdadm or BTRFS RAID instead |
| RAID (AMD) | ⚠️ | Prefer software RAID |

### Audio

| Vendor | Status | Notes |
|--------|--------|-------|
| Intel HDA | ✅ | Standard audio |
| Realtek ALC series | ✅ | Most common |
| USB Audio | ✅ | Plug and play |
| Bluetooth Audio | ✅ | A2DP, HFP supported |
| HDMI/DP Audio | ✅ | Through GPU |

## Peripherals

### Input Devices

| Device Type | Status | Notes |
|-------------|--------|-------|
| USB Keyboard/Mouse | ✅ | Plug and play |
| Bluetooth KB/Mouse | ✅ | Pair via Settings |
| Touchpads | ✅ | Multi-touch gestures |
| Touchscreens | ✅ | Touch and stylus |
| Drawing tablets (Wacom) | ✅ | Pressure sensitivity |
| Drawing tablets (Huion/XP) | ⚠️ | May need drivers |

### Displays

| Connection | Status | Notes |
|------------|--------|-------|
| HDMI | ✅ | Hotplug support |
| DisplayPort | ✅ | Including USB-C DP Alt Mode |
| USB-C/Thunderbolt | ✅ | Daisy chaining supported |
| HiDPI (4K+) | ✅ | Automatic scaling |
| HDR | ⚠️ | Limited application support |
| Variable Refresh Rate | ✅ | Freesync/G-Sync |

### Printers

| Vendor | Status | Notes |
|--------|--------|-------|
| HP | ✅ | HPLIP drivers included |
| Brother | ✅ | Drivers available |
| Canon | ⚠️ | Some models need setup |
| Epson | ✅ | ESC/P-R drivers |

### Cameras

| Type | Status | Notes |
|------|--------|-------|
| Built-in webcam | ✅ | UVC standard |
| USB webcams | ✅ | Most work out of box |
| IR cameras | ⚠️ | For Windows Hello style login |

## AI Acceleration

### Local AI Hardware

| Hardware | Status | Notes |
|----------|--------|-------|
| NVIDIA CUDA | ✅ | Full acceleration |
| AMD ROCm | ⚠️ | Limited model support |
| Intel OpenVINO | ✅ | Integrated GPU/NPU |
| Apple Neural Engine | ❌ | Not applicable |
| Google Coral TPU | 🧪 | Testing in progress |
| Qualcomm NPU | 🧪 | Snapdragon X Elite |

### Recommended Specs for AI

| Use Case | Minimum | Recommended |
|----------|---------|-------------|
| Basic chat (3B models) | 8GB RAM, CPU | 8GB RAM, any GPU |
| Standard chat (7-8B) | 16GB RAM, 4GB VRAM | 16GB RAM, 8GB VRAM |
| Advanced (13B+) | 32GB RAM, 12GB VRAM | 32GB RAM, RTX 4070+ |
| Code generation | 16GB RAM, 8GB VRAM | 32GB RAM, RTX 4070+ |

## Known Issues

### Critical Issues

| Issue | Affected Hardware | Workaround |
|-------|-------------------|------------|
| Sleep/resume fails | Some AMD laptops | Disable S3, use s2idle |
| Touchpad unresponsive | Some I2C touchpads | Use psmouse driver |
| External monitor issues | USB-C docks | Use direct connection |

### Minor Issues

| Issue | Affected Hardware | Status |
|-------|-------------------|--------|
| Fingerprint enrollment | Some models | Being investigated |
| Ambient light sensor | Rare | Manual brightness control |
| Custom fan curves | Gaming laptops | Use alternative tools |

## Reporting Hardware Issues

If you encounter hardware issues:

1. Check this document first
2. Search existing issues: https://github.com/hectormr/lifeos/issues
3. Run diagnostic tool:
   ```bash
   life system diagnose --hardware
   ```
4. File a report with:
   ```bash
   life feedback bug --hardware
   ```

Include:
- Output of `fastfetch` or `neofetch`
- `lspci -v` and `lsusb -v` output
- Kernel messages: `dmesg | grep -i error`
- Detailed description of the issue

## Contributing

Help improve hardware support by:
1. Testing on your hardware
2. Reporting compatibility status
3. Contributing fixes
4. Updating this document

See [CONTRIBUTING.md](../CONTRIBUTING.md) for details.

## See Also

- [INSTALLATION.md](./INSTALLATION.md) - Installation guide
- [Arch Wiki - Hardware](https://wiki.archlinux.org/title/Category:Hardware) - Detailed hardware info
- [Linux Hardware Database](https://linux-hardware.org/) - Community hardware database
