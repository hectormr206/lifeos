# LifeOS Theme System

LifeOS features a comprehensive theming system with multiple variants, accent colors, and customization options.

## Overview

The theme system provides:
- **Two Theme Variants**: Simple (minimal) and Pro (feature-rich)
- **Dynamic Modes**: Dark, Light, or Auto (follows system)
- **Accent Colors**: 9 preset colors to personalize your system
- **Wallpaper Management**: Easy wallpaper switching and organization
- **Import/Export**: Share your theme configurations

## Theme Variants

### Simple Theme ✨

A clean, minimal interface optimized for focus.

**Features:**
- Distraction-free workspace
- Essential tools only
- Fast and lightweight
- Clean typography
- Generous whitespace

**Best for:**
- Users who prefer minimalism
- Focus-heavy work
- Lower-powered hardware
- Clean aesthetic preference

```bash
life theme variant simple
```

### Pro Theme 🚀

A feature-rich interface with advanced tools and panels.

**Features:**
- Advanced panels and sidebars
- Integrated AI assistant panel
- Power user tools
- Information-dense layout
- Quick access shortcuts

**Best for:**
- Power users
- Multi-tasking workflows
- Developers and creators
- Users who want quick access to tools

```bash
life theme variant pro
```

## Appearance Modes

### Dark Mode 🌙

Easy on the eyes, perfect for low-light environments.

```bash
life theme mode dark
# or
life theme appearance --dark
```

### Light Mode ☀️

Clean and bright, great for well-lit environments.

```bash
life theme mode light
# or
life theme appearance --light
```

### Auto Mode 🌓

Automatically switches based on system preference or time of day.

```bash
life theme mode auto
# or
life theme appearance --auto
```

## Accent Colors

Personalize your system with 9 preset accent colors:

| Color | Preview | Best For |
|-------|---------|----------|
| 🔵 Blue | Classic LifeOS | Professional, default |
| 🟣 Purple | Creative | Artistic, unique |
| 🩷 Pink | Playful | Fun, energetic |
| 🔴 Red | Energetic | Bold, attention |
| 🟠 Orange | Warm | Friendly, welcoming |
| 🟡 Yellow | Sunny | Optimistic, bright |
| 🟢 Green | Natural | Calm, eco-friendly |
| 🩵 Teal | Modern | Fresh, balanced |
| ⚪ Gray | Neutral | Minimal, understated |

```bash
# List all colors
life theme accent --list

# Set accent color
life theme accent blue
life theme accent purple
life theme accent teal
```

## Focus Presets

LifeOS provides visual comfort presets optimized for different work scenarios. These presets adjust blue light filtering, color temperature, and saturation to reduce eye strain and improve focus.

### Balanced Preset ⚖️

A balanced setting for general work with moderate eye protection.

**Settings:**
- Blue light reduction: ~30%
- Color temperature: 4500K (mild warm)
- Saturation: Standard
- Best for: General office work, browsing, communication

```bash
life focus balanced
```

**When to use:**
- Daytime work sessions
- Mixed activities (reading, writing, coding)
- When you want subtle eye protection without noticeable color shift

### Vivid Preset 🎨

Enhanced colors with warm tones for creative work and media.

**Settings:**
- Blue light reduction: ~20%
- Color temperature: 5000K (slightly warm)
- Saturation: Enhanced (+15%)
- Best for: Design work, photo/video editing, presentations

```bash
life focus vivid
```

**When to use:**
- Creative work requiring color accuracy
- Presentations and meetings
- When you want vibrant visuals

### Night Preset 🌙

Maximum eye protection for late evening and night work.

**Settings:**
- Blue light reduction: ~70%
- Color temperature: 2700K (warm amber)
- Saturation: Reduced
- Best for: Evening work, pre-sleep screen time

```bash
life focus night
```

**When to use:**
- Working after sunset
- 2+ hours before bedtime
- In low-light environments

### Custom Preset

Create your own preset with specific parameters:

```bash
# Custom intensity (0-100)
life focus night --intensity 80

# Custom color temperature (2700K-6500K)
life focus --temperature 3500

# Combine settings
life focus --intensity 60 --temperature 4000
```

### Automatic Scheduling

Enable automatic preset switching based on time:

```bash
# Auto-switch: balanced during day, night after sunset
life focus auto

# Custom schedule
life focus night --schedule 20:00-06:00
```

### Preset Comparison

| Preset | Blue Light ↓ | Temperature | Saturation | Best For |
|--------|--------------|-------------|------------|----------|
| Balanced | ~30% | 4500K | Standard | General work |
| Vivid | ~20% | 5000K | +15% | Creative work |
| Night | ~70% | 2700K | Reduced | Evening/bedtime |

### Eye Comfort Tips

1. **20-20-20 Rule**: Every 20 minutes, look at something 20 feet away for 20 seconds
2. **Brightness Match**: Match screen brightness to room lighting
3. **Night Mode Early**: Enable night mode 2-3 hours before bed
4. **Take Breaks**: Even with eye protection, regular breaks are important

### Validation

To validate that Night Mode effectively reduces eye strain during extended sessions:

```bash
# Run the validation script for 3+ hour sessions
./scripts/validate-night-mode.sh start

# See docs/night-mode-validation.md for full procedure
```

## Wallpaper Management

### Setting Wallpapers

```bash
# Set desktop wallpaper
life theme wallpaper set ~/Pictures/wallpaper.jpg

# Set lock screen wallpaper
life theme wallpaper set ~/Pictures/lock.jpg --lock

# Set both
life theme wallpaper set ~/Pictures/wallpaper.jpg --both

# Download and set
life theme wallpaper download https://example.com/image.jpg --name my-wallpaper
```

### Wallpaper Collections

LifeOS includes curated wallpaper collections:

```bash
# List available wallpapers
life theme wallpaper list

# List all (including system)
life theme wallpaper list --all

# Get current wallpaper
life theme wallpaper get
```

### Automatic Cycling

Set up rotating wallpapers:

```bash
# Cycle every 5 minutes
life theme wallpaper cycle --interval 300

# Cycle from custom directory
life theme wallpaper cycle --directory ~/Pictures/Wallpapers
```

For persistent cycling, add to crontab:

```bash
# Edit crontab
crontab -e

# Add entry (every 15 minutes)
*/15 * * * * export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id - u)/bus; /usr/local/bin/life theme wallpaper cycle
```

## Configuration Management

### Export Theme

Save your theme configuration:

```bash
# Export to default location
life theme config export

# Export to specific file
life theme config export ~/backups/my-theme.json
```

### Import Theme

Apply a saved theme:

```bash
life theme config import ~/backups/my-theme.json
```

### Reset to Defaults

```bash
life theme config reset
```

## Theme Configuration File

Theme configurations are stored in JSON format:

```json
{
  "variant": "simple",
  "mode": "dark",
  "accent_color": "blue",
  "wallpaper": {
    "desktop": "/home/user/Pictures/wallpaper.jpg",
    "lock": "/home/user/Pictures/lock.jpg",
    "mode": "zoom"
  },
  "appearance": {
    "dark_mode": true,
    "follow_system": false,
    "contrast": "default"
  }
}
```

## Quick Reference

### Commands

```bash
# View current theme status
life theme status

# List all available themes
life theme list

# Preview themes
life theme preview simple
life theme preview pro
```

### Complete Examples

**Developer Setup:**
```bash
life theme variant pro
life theme mode dark
life theme accent teal
life theme wallpaper set ~/Pictures/code-wallpaper.jpg
```

**Minimal Setup:**
```bash
life theme variant simple
life theme mode light
life theme accent gray
life theme wallpaper set ~/Pictures/minimal.jpg
```

**Auto-switching Setup:**
```bash
life theme variant pro
life theme mode auto
life theme accent blue
```

## Integration with Desktop

The theme system integrates with:

- **GNOME**: Full GTK and Shell theming
- **Flatpak Apps**: Consistent styling
- **Terminal**: Color scheme matching
- **LifeOS CLI**: Color output theming

## Troubleshooting

### Theme Not Applying

```bash
# Check GNOME settings
# Some settings require GNOME session

# Restart GNOME Shell (Alt+F2, type 'r', Enter)
# Or logout/login
```

### Wallpaper Not Changing

```bash
# Verify image exists and is readable
ls -l ~/Pictures/wallpaper.jpg

# Check supported formats
# JPG, PNG supported
# WebP may need additional codecs
```

### Reset Everything

```bash
life theme config reset
```

## Customization Tips

### 1. Create Theme Presets

Save different themes for different activities:

```bash
# Work theme
life theme config export ~/.config/lifeos/work-theme.json

# Gaming theme
life theme config export ~/.config/lifeos/gaming-theme.json

# Switch between them
life theme config import ~/.config/lifeos/work-theme.json
```

### 2. Time-Based Switching

Use cron to switch themes based on time:

```bash
# Morning (light theme)
0 8 * * * life theme mode light

# Evening (dark theme)
0 18 * * * life theme mode dark
```

### 3. Dynamic Wallpapers

Use tools like `variety` or `wallch` with LifeOS:

```bash
# Install variety
life store install peterlevi.variety

# Configure to work with LifeOS theme
```

## Advanced: Creating Custom Themes

For advanced users, create custom theme files:

```json
{
  "variant": "custom",
  "custom_settings": {
    "panel_position": "bottom",
    "dock_enabled": true,
    "dock_position": "left",
    "icon_theme": "Papirus-Dark",
    "cursor_theme": "Adwaita"
  }
}
```

## Future Features

Planned theme enhancements:
- [ ] Custom CSS injection
- [ ] Community theme gallery
- [ ] AI-generated themes
- [ ] Dynamic weather-based themes
- [ ] Per-app theming

## See Also

- [GNOME Tweaks](https://wiki.gnome.org/Apps/Tweaks) - Advanced GNOME customization
- [r/unixporn](https://reddit.com/r/unixporn) - Community inspiration
- [LifeOS CLI](CLI.md) - Complete CLI reference
