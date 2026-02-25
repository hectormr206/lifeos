# LifeOS App Store

The LifeOS App Store provides a curated, user-friendly way to install applications using Flatpak.

## Overview

The App Store integrates with:
- **Flathub**: The primary source for applications
- **LifeOS Curated**: Hand-picked apps optimized for LifeOS
- **Custom Sources**: Add your own Flatpak repositories

## Features

- 🔍 **Smart Search**: Find apps by name, description, or category
- 📂 **Categories**: Browse apps by type (Productivity, Development, Games, etc.)
- ⭐ **Featured**: Popular and recommended applications
- 🎯 **Curated**: LifeOS-tested and approved apps
- 🔄 **Updates**: Automatic update checking and installation
- 💾 **Management**: List, install, remove apps easily

## Usage

### Basic Commands

```bash
# Search for apps
life store search firefox
life store search editor --category Development

# Browse categories
life store categories

# View featured apps
life store featured

# Install an app
life store install org.mozilla.firefox
life store install flathub:com.spotify.Client

# Remove an app
life store remove org.mozilla.firefox

# List installed apps
life store list
life store list --detailed

# Update apps
life store update              # Update all
life store update firefox      # Update specific app

# Check for updates
life store check

# View app details
life store info org.mozilla.firefox

# View LifeOS curated apps
life store curated
```

### Managing Sources

```bash
# List configured sources
life store sources list

# Add a source
life store sources add flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo

# Remove a source
life store sources remove flathub-beta

# Update source metadata
life store sources update
```

## App Categories

| Category | Description | Example Apps |
|----------|-------------|--------------|
| 🌐 Network | Browsers, email, chat | Firefox, Thunderbird, Discord |
| 🎨 Graphics | Image editing, drawing | GIMP, Inkscape, Blender |
| 🎵 Audio | Music players, editors | Spotify, Audacity, LMMS |
| 🎬 Video | Players, editors | VLC, OBS Studio, Kdenlive |
| 🎮 Games | Games and emulators | Steam, RetroArch |
| 📝 Office | Documents, spreadsheets | LibreOffice, Obsidian |
| 💻 Development | IDEs, tools | VS Code, GNOME Builder, Git |
| 🔬 Science | Scientific apps | Jupyter, RStudio |
| 🎓 Education | Learning tools | Anki, GeoGebra |
| 🔒 System | System utilities | Extensions Manager |

## Curated Applications

### Essential
Applications every LifeOS user should have:
- **Firefox**: Privacy-focused web browser
- **Thunderbird**: Email client
- **VLC**: Universal media player
- **Transmission**: BitTorrent client

### Productivity
Boost your workflow:
- **LibreOffice**: Full office suite
- **Obsidian**: Knowledge management
- **draw.io**: Diagrams and flowcharts
- **Notion** (web): All-in-one workspace

### Development
Tools for developers:
- **VS Code**: Popular code editor
- **GNOME Builder**: Native Linux IDE
- **GitHub Desktop**: Git GUI
- **Docker Desktop**: Container management
- **Postman**: API development

### Creative
Unleash creativity:
- **GIMP**: Professional image editor
- **Blender**: 3D creation suite
- **Inkscape**: Vector graphics
- **Krita**: Digital painting
- **Audacity**: Audio editing

### Communication
Stay connected:
- **Discord**: Community chat
- **Signal**: Private messaging
- **Zoom**: Video conferencing
- **Slack**: Team communication

### Entertainment
Relax and enjoy:
- **Spotify**: Music streaming
- **Steam**: Gaming platform
- **Plex**: Media server
- **Jellyfin**: Open source media

## Advanced Usage

### Batch Operations

```bash
# Install multiple apps
life store install org.mozilla.firefox com.spotify.Client com.visualstudio.code

# Export installed apps list
life store list > my-apps.txt

# Reinstall from list
while read app; do
    life store install "$app"
done < my-apps.txt
```

### Permissions Management

```bash
# View app permissions
flatpak info --show-permissions org.mozilla.firefox

# Override permissions
flatpak override --user --socket=wayland org.mozilla.firefox

# Reset permissions
flatpak override --user --reset org.mozilla.firefox
```

### Troubleshooting

```bash
# Repair installation
flatpak repair

# Update app data
flatpak update --appstream

# Clear app data
rm -rf ~/.var/app/org.mozilla.firefox

# View app logs
flatpak run org.mozilla.firefox 2>&1 | tee firefox.log
```

## Configuration

### Default Installation

By default, apps are installed per-user (`--user`). To change:

```bash
# Install system-wide (requires sudo)
life store install firefox --system

# Set default behavior
life config set store.system_default true
```

### Auto-Updates

Enable automatic updates:

```bash
# Check for updates daily
systemctl --user enable --now flatpak-user-update.timer

# Or configure in LifeOS settings
life config set store.auto_update true
```

## Comparison with Other Package Managers

| Feature | LifeOS Store | Flatpak (CLI) | DNF | AppImage |
|---------|--------------|---------------|-----|----------|
| GUI | ✓ | ✗ | ✗ | ✗ |
| Sandboxed | ✓ | ✓ | ✗ | ✗ |
| Automatic updates | ✓ | ✓ | ✓ | ✗ |
| Curated selection | ✓ | ✗ | ✗ | ✗ |
| AI recommendations | ✓ | ✗ | ✗ | ✗ |
| Rollback support | ✓ | ✓ | ✗ | ✗ |

## Tips

### 1. Quick Install with AI

```bash
life ai do "install a video editor"
```

### 2. Keyboard Shortcuts

Add to your shell config:

```bash
alias ls-store='life store'
alias ls-install='life store install'
alias ls-search='life store search'
```

### 3. Backup Installed Apps

```bash
life store list --format=ids > ~/backups/installed-apps.txt
```

### 4. Find Alternatives

```bash
# Search for similar apps
life store search "photo editor"
life store search "alternative to photoshop"
```

## Privacy & Security

All apps from the Store:
- Run in sandboxed environments
- Request permissions explicitly
- Are verified by Flathub (when available)
- Can be easily removed completely

Review permissions before installing:
```bash
life store info org.example.App
```

## Contributing

To suggest apps for curation:
1. Test the app thoroughly
2. File an issue with `#app-suggestion` tag
3. Include why it should be curated

See [CONTRIBUTING.md](../CONTRIBUTING.md) for details.

## See Also

- [Flatpak Documentation](https://docs.flatpak.org/)
- [Flathub Apps](https://flathub.org/apps)
- [Flatseal](https://flathub.org/apps/com.github.tchx84.Flatseal) - Permission manager
