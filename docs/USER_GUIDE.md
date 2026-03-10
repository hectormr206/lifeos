# LifeOS User Guide

Welcome to LifeOS - Your AI-First Linux Distribution!

## Quick Start

### First Boot

When you start LifeOS for the first time, the **First Boot Wizard** will automatically launch. This wizard helps you:

1. **Create your user account** - Set up your username, password, and full name
2. **Configure system settings** - Set your timezone, locale, and hostname
3. **Choose your theme** - Select between "Simple" (clean, minimal) or "Pro" (power user, advanced)
4. **Set privacy preferences** - Control analytics and telemetry
5. **Configure AI** - Enable the local AI assistant and select your default model
6. **Review and apply** - Confirm your settings before they're applied

### Manual First Boot

If you need to run the first boot wizard manually:

```bash
# Interactive wizard
life first-boot

# Automatic setup with defaults
life first-boot --auto

# Specify options
life first-boot --username myuser --hostname mypc --theme pro
```

## Daily Usage

### System Status

Check your system status at any time:

```bash
life status
```

This shows:
- System health
- bootc status
- Available updates
- AI service status
- Resource usage

### AI Assistant

LifeOS includes a local AI assistant powered by llama-server (llama.cpp):

```bash
# Start AI chat
life ai chat

# List available models
life ai models

# Pull a new model
life ai pull qwen3.5-4b

# Start/stop AI service
life ai start
life ai stop
```

### System Updates

LifeOS uses atomic updates via bootc:

```bash
# Check for updates
life update --check

# Apply updates (requires reboot)
life update

# See what would change (dry run)
life update --dry-run
```

### Rollback

If something goes wrong after an update:

```bash
# Rollback to previous version
life rollback

# Then reboot
sudo reboot
```

### Development Containers (Toolbox)

LifeOS keeps the base system immutable, but the host image already includes the baseline required
to self-host LifeOS development: `cargo`, `rustc`, `rustfmt`, `cargo clippy`, `cargo-audit`,
`pkg-config`, and the GTK/libadwaita development headers needed by `lifeosd --all-features`.

Use `toolbox` for extra development software (Node.js, npm, custom SDKs) so those stacks stay
inside a mutable container and do not modify the host OS.

What `toolbox` is:
- A developer shell container integrated with Fedora/Podman
- Great for per-stack environments beyond the host baseline (for example, one container for Node)
- Reusable across projects while keeping the host clean

Node.js and npm example:

```bash
# Create a toolbox once
toolbox create dev-node

# Enter toolbox
toolbox enter dev-node

# Install packages inside toolbox
sudo dnf install -y nodejs npm

# Verify
node --version
npm --version
```

Important behavior:
- `node`/`npm` are available only while inside `toolbox`
- Outside toolbox, host commands remain unchanged
- Exit toolbox with `exit` (or `Ctrl+D`)

Useful toolbox commands:

```bash
# Enter existing toolbox
toolbox enter dev-node

# List toolboxes
toolbox list

# Remove toolbox when no longer needed
toolbox rm dev-node
```

## Configuration

### System Configuration

View and modify your configuration:

```bash
# Show current config
life config show

# Get a specific value
life config get ai.model

# Set a value
life config set ai.model Qwen3.5-4B-Q4_K_M.gguf
```

### COSMIC Desktop Settings

LifeOS configures COSMIC desktop automatically, but you can customize:

```bash
# Change theme
gsettings set io.lifeos.desktop theme-variant pro

# Toggle welcome on login
gsettings set io.lifeos.desktop show-welcome-on-login true

# Change dock position
gsettings set io.lifeos.desktop dock-position right
```

## Privacy

### Your Data

LifeOS respects your privacy:

- **Anonymous analytics** - Optional, off by default
- **Crash telemetry** - Optional, off by default
- **Local AI only** - All AI processing happens on your machine
- **No cloud dependency** - Works completely offline

### Managing Privacy Settings

```bash
# Check current settings
gsettings get io.lifeos.desktop privacy-analytics
gsettings get io.lifeos.desktop privacy-telemetry

# Enable/disable
gsettings set io.lifeos.desktop privacy-analytics false
gsettings set io.lifeos.desktop privacy-telemetry false
```

## Troubleshooting

### First Boot Issues

If the first boot wizard doesn't start:

```bash
# Check if first boot was completed
cat /var/lib/lifeos/.first-boot-complete

# Force re-run
life first-boot --force
```

### AI Not Working

```bash
# Check llama-server status
systemctl status llama-server

# Start AI service
life ai start

# Check GPU acceleration
nvidia-smi  # For NVIDIA
rocminfo    # For AMD
```

On image-mode/bootc installations, avoid using `akmods` directly on the host when `/usr` is read-only.
Use `life update`/`bootc upgrade` to move to an image that already contains compatible NVIDIA kernel modules.
Recent release images include bootc kargs to prefer proprietary NVIDIA over `nouveau`.
If Secure Boot is enabled, validate/enroll the LifeOS NVIDIA MOK certificate:

```bash
sudo lifeos-nvidia-secureboot.sh status
sudo lifeos-nvidia-secureboot.sh enroll
sudo reboot
```

More details: [`docs/NVIDIA_SECURE_BOOT.md`](./NVIDIA_SECURE_BOOT.md).

### Update Issues

```bash
# Check bootc status
bootc status

# Manual recovery
life recover

# View logs
journalctl -u lifeosd -f
```

### Network Issues

```bash
# Check connectivity
ping 1.1.1.1

# Check network manager
systemctl status NetworkManager

# Restart networking
sudo systemctl restart NetworkManager
```

## Tips and Tricks

### Keyboard Shortcuts

LifeOS provides convenient keyboard shortcuts:

- `Super` - Open activities overview
- `Super + /` - AI assistant quick access (configurable)
- `Super + T` - Terminal
- `Super + B` - Web browser
- `Super + F` - File manager
- `Alt + F2` - Run command
- `Ctrl + Alt + T` - Terminal (classic)

### Capsules

Save and restore your system state:

```bash
# Create a capsule (backup)
life capsule create my-backup

# List capsules
life capsule list

# Restore from capsule
life capsule restore my-backup
```

### Intents

Use intents for common tasks:

```bash
# Create a work session intent
life intents create work-session --description "Focus time for deep work"

# List intents
life intents list

# Activate an intent
life intents activate work-session
```

## Getting Help

### In-System Help

```bash
# Get help for any command
life --help
life first-boot --help
life ai --help
```

### Online Resources

- **Documentation**: https://docs.lifeos.io
- **Community Forum**: https://community.lifeos.io
- **GitHub**: https://github.com/lifeos/lifeos

### Support

For technical support:
- Check this guide first
- Search the community forum
- Open an issue on GitHub
- Join our Discord: https://discord.lifeos.io

## Advanced Topics

### System Services

LifeOS runs several background services:

```bash
# Check daemon status
systemctl status lifeosd

# View service logs
journalctl -u lifeosd -f

# Check timers
systemctl list-timers lifeos-*
```

### Customizing the Boot Process

```bash
# Edit daemon config
sudo nano /etc/lifeos/daemon.toml

# Reload daemon
sudo systemctl restart lifeosd
```

### Development Mode

For development and testing:

```bash
# Enter lab mode
life lab start

# Run tests
life lab test

# Generate report
life lab report
```

---

**Welcome to LifeOS!** 🚀

*The first Linux distribution built for the AI age.*
