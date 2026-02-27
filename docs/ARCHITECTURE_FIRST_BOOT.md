# LifeOS First Boot Architecture

## Overview

The first-boot experience is the user's initial interaction with LifeOS. It must be:

- **Fast** - Complete setup in under 5 minutes
- **Friendly** - Clear, approachable language
- **Flexible** - Support both automated and interactive modes
- **Fault-tolerant** - Handle errors gracefully

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     First Boot Flow                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐                                                │
│  │  boot.target │                                                │
│  └──────┬───────┘                                                │
│         │                                                        │
│         ▼                                                        │
│  ┌─────────────────────┐                                         │
│  │ lifeos-first-boot   │  Check /var/lib/lifeos/.first-boot-    │
│  │ .desktop (autostart)│  complete marker                        │
│  └──────────┬──────────┘                                         │
│             │                                                    │
│             ▼                                                    │
│  ┌─────────────────────┐                                         │
│  │   life first-boot   │  Main entry point                       │
│  └──────────┬──────────┘                                         │
│             │                                                    │
│     ┌───────┴───────┐                                            │
│     ▼               ▼                                            │
│ ┌─────────┐   ┌──────────┐                                       │
│ │ --auto  │   │interactive                                       │
│ │ (unatt) │   │ (wizard) │                                       │
│ └────┬────┘   └────┬─────┘                                       │
│      │             │                                              │
│      └──────┬──────┘                                              │
│             ▼                                                     │
│  ┌─────────────────────┐                                          │
│  │ System Verification │  Check: bootc, partitions, network,      │
│  │                     │  GPU, storage                             │
│  └──────────┬──────────┘                                          │
│             │                                                      │
│             ▼                                                      │
│  ┌─────────────────────┐                                          │
│  │ Configuration Steps │  User, System, Theme, Privacy, AI        │
│  └──────────┬──────────┘                                          │
│             │                                                      │
│             ▼                                                      │
│  ┌─────────────────────┐                                          │
│  │ Apply Configuration │  Create user, set hostname/locale,       │
│  │                     │  save config                              │
│  └──────────┬──────────┘                                          │
│             │                                                      │
│             ▼                                                      │
│  ┌─────────────────────┐                                          │
│  │  Setup AI Runtime   │  Start llama-server, download             │
│  │                     │  default GGUF model                       │
│  └──────────┬──────────┘                                          │
│             │                                                      │
│             ▼                                                      │
│  ┌─────────────────────┐                                          │
│  │ Configure Desktop   │  COSMIC settings, wallpaper, dock        │
│  └──────────┬──────────┘                                          │
│             │                                                      │
│             ▼                                                      │
│  ┌─────────────────────┐                                          │
│  │ Mark Complete       │  Create /var/lib/lifeos/.first-boot-    │
│  │                     │  complete marker                          │
│  └─────────────────────┘                                          │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Autostart Desktop File

**Location**: `/etc/xdg/autostart/lifeos-first-boot.desktop`

Triggers on first graphical login. Checks for completion marker before running.

### 2. CLI Command

**Module**: `cli/src/commands/first_boot.rs`

Implements the `life first-boot` command with:
- Interactive wizard using `dialoguer`
- Automatic mode for unattended setup
- System verification checks
- Configuration application

### 3. Configuration State

**Struct**: `FirstBootState`

Captures all user preferences during setup:
```rust
pub struct FirstBootState {
    pub hostname: String,
    pub username: String,
    pub fullname: String,
    pub timezone: String,
    pub locale: String,
    pub keyboard: String,
    pub theme: ThemeChoice,
    pub privacy_analytics: bool,
    pub privacy_telemetry: bool,
    pub ai_enabled: bool,
    pub ai_model: String,
    pub network_configured: bool,
}
```

### 4. Verification System

**Struct**: `SystemVerification`

Performs checks:
- bootc status and operability
- Partition layout verification
- Network connectivity (ping)
- GPU detection (NVIDIA, AMD, Intel, Apple)
- Storage space check

### 5. COSMIC Desktop Integration

Applies desktop settings:
- Theme variant (Simple/Pro)
- Wallpaper
- Dock position
- Desktop icons
- Keyboard shortcuts

## Flow States

### Interactive Mode

1. **Welcome Banner** - ASCII art + introduction
2. **User Account** - Username, full name, password
3. **System Settings** - Hostname, timezone, locale
4. **Theme Selection** - Simple vs Pro explanation
5. **Privacy Settings** - Analytics and telemetry
6. **AI Configuration** - Enable/disable, model selection
7. **Review** - Confirm all settings
8. **Apply** - Execute configuration
9. **Complete** - Summary and next steps

### Automatic Mode

Uses sensible defaults or provided arguments:
```bash
life first-boot --auto --username dev --hostname workstation --theme pro
```

## Error Handling

| Stage | Error | Action |
|-------|-------|--------|
| Verification | bootc not found | Continue with warning |
| Verification | No network | Prompt to configure or continue offline |
| Verification | Low disk space | Warning, suggest cleanup |
| User Creation | User already exists | Skip with warning |
| AI Setup | llama-server fails | Continue without AI, notify user |
| AI Setup | Model download fails | Continue, background download |
| Desktop Config | gsettings fails | Log warning, continue |

## Security Considerations

1. **Password handling** - Written to temp file only during setup, deleted immediately after
2. **Root execution** - Wizard prompts for elevation when needed
3. **Network** - No external calls except for AI model download (user-triggered)
4. **Privacy** - Analytics and telemetry default to OFF

## Files and Locations

| Path | Purpose |
|------|---------|
| `/var/lib/lifeos/.first-boot-complete` | Completion marker |
| `/tmp/lifeos-setup-password` | Temporary password file (deleted after use) |
| `~/.config/lifeos/lifeos.toml` | User configuration |
| `/etc/lifeos/lifeos.toml` | System-wide configuration |
| `/usr/share/glib-2.0/schemas/io.lifeos.desktop.gschema.xml` | GSettings schema |

## Testing

### Manual Testing

```bash
# Clean slate
sudo rm /var/lib/lifeos/.first-boot-complete

# Run wizard
life first-boot --force

# Or automatic mode
life first-boot --auto --force
```

### VM Testing

```bash
# Boot fresh VM
# First boot wizard should auto-start
# Complete setup
# Reboot and verify settings persist
```

## Future Enhancements

- [ ] Graphical wizard (GTK4)
- [ ] Network configuration UI
- [ ] Disk encryption setup
- [ ] Cloud account integration
- [ ] SSH key generation
- [ ] Dotfiles import
