# LifeOS Icon Theme

## Overview

LifeOS uses an icon theme strategy based on **Adwaita inheritance with LifeOS overrides**. This approach provides:

- **Consistency**: Inherits the well-tested Adwaita icon set
- **Efficiency**: Only custom icons need to be maintained
- **Compatibility**: Works with all GTK4/GNOME applications
- **Maintainability**: Upstream Adwaita updates flow through automatically

## Inheritance Strategy

```
LifeOS Icon Theme
├── Inherits: Adwaita (fallback for all missing icons)
├── scalable/
│   ├── apps/         → LifeOS-specific app icons
│   ├── actions/      → Custom action icons
│   ├── categories/   → Custom category icons
│   ├── status/       → Custom status icons
│   ├── places/       → Custom folder/place icons
│   └── mimetypes/    → Custom file type icons
└── index.theme       → Theme configuration
```

### How Inheritance Works

1. **Application requests an icon** (e.g., `lifeos`)
2. **LifeOS theme is searched first** → `/usr/share/icons/LifeOS/scalable/apps/lifeos.svg`
3. **If not found, Adwaita is searched** → `/usr/share/icons/Adwaita/...`
4. **Final fallback**: hicolor icon theme

## Icon Guidelines

### Naming Conventions

| Type | Pattern | Example |
|------|---------|---------|
| Application | `lifeos[-component]` | `lifeos`, `lifeos-settings`, `lifeos-terminal` |
| Action | `lifeos-action-name` | `lifeos-action-apply`, `lifeos-action-sync` |
| Status | `lifeos-status-name` | `lifeos-status-active`, `lifeos-status-syncing` |
| Category | `lifeos-category-name` | `lifeos-category-system`, `lifeos-category-ai` |

### Design Specifications

- **Format**: SVG (scalable vector graphics)
- **Canvas**: 128x128px viewBox
- **Style**: Simple, geometric, flat design
- **Colors**: Use LifeOS brand palette
  - Primary: `#0f4c75`
  - Accent: `#3282b8`
  - Background: `#1a1a2e`
  - Text: `#e8e8e8`

### SVG Template

```xml
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="128" height="128">
  <title>Icon Name</title>
  <desc>Description</desc>
  
  <!-- Icon content here -->
  <!-- Use LifeOS brand colors -->
</svg>
```

## Custom Icons

### Current Custom Icons

| Icon | Path | Purpose |
|------|------|---------|
| `lifeos` | `scalable/apps/lifeos.svg` | Main application icon |
| `lifeos-daemon` | `scalable/apps/lifeos-daemon.svg` | Daemon service icon (TODO) |
| `lifeos-settings` | `scalable/apps/lifeos-settings.svg` | Settings icon (TODO) |

### Icons to Create

- [ ] `lifeos-daemon` - Background service indicator
- [ ] `lifeos-settings` - Configuration panel
- [ ] `lifeos-terminal` - Terminal/CLI icon
- [ ] `lifeos-ai` - AI assistant icon
- [ ] `lifeos-update` - Update manager icon

## Integration

### GTK Application Usage

```rust
// Set application icon
let app = gtk::Application::builder()
    .application_id("com.lifeos.LifeOS")
    .build();

// Icon is automatically loaded from:
// /usr/share/icons/LifeOS/scalable/apps/lifeos.svg
```

### Desktop File

```ini
[Desktop Entry]
Name=LifeOS
Exec=life
Icon=lifeos
Type=Application
Categories=System;
```

### Icon Theme Installation

Icons are installed via the container image at:
```
/usr/share/icons/LifeOS/
```

Users can select the icon theme via:
- GNOME Tweaks
- `gsettings set org.gnome.desktop.interface icon-theme 'LifeOS'`

## Testing

### Verify Icon Theme

```bash
# Check theme exists
ls -la /usr/share/icons/LifeOS/

# Verify inheritance
grep Inherits /usr/share/icons/LifeOS/index.theme

# Test icon lookup
gtk-update-icon-cache /usr/share/icons/LifeOS/
```

### Preview Icons

```bash
# Using gtk3-icon-browser
gtk3-icon-browser

# Or manually
gio info -a standard::icon /usr/share/icons/LifeOS/scalable/apps/lifeos.svg
```

## Maintenance

### Updating Icons

1. Edit SVG files in `image/files/usr/share/icons/LifeOS/scalable/`
2. Follow naming conventions
3. Test in both dark and light themes
4. Run `gtk-update-icon-cache` if needed

### Upstream Adwaita Updates

Adwaita updates are handled by the base system. LifeOS automatically benefits from:
- New icons added to Adwaita
- Bug fixes in existing icons
- Accessibility improvements

## Accessibility

- All icons should be distinguishable by shape, not just color
- Provide symbolic variants for high-contrast mode
- Consider colorblind users when designing

## References

- [Freedesktop Icon Theme Specification](https://specifications.freedesktop.org/icon-theme-spec/icon-theme-spec-latest.html)
- [GNOME Icon Design Guidelines](https://developer.gnome.org/hig/stable/icon-design.html.en)
- [Adwaita Icon Theme](https://gitlab.gnome.org/GNOME/adwaita-icon-theme)
