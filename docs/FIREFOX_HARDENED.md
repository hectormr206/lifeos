# Firefox Hardened Integration

This document describes the Firefox Hardened integration in LifeOS, including privacy policies, extensions, and visual theming.

## Overview

LifeOS ships with a privacy-hardened Firefox configuration that:

- **Disables all telemetry** and data collection by default
- **Enforces privacy settings** via enterprise policies (cannot be changed by users)
- **Pre-installs uBlock Origin** as a locked extension for ad/tracking blocking
- **Integrates visually** with LifeOS design tokens via custom `userChrome.css`
- **Supports Wayland natively** for optimal performance on modern displays

## Architecture

Firefox Hardened uses a 4-layer approach:

```
┌─────────────────────────────────────────────────────────────┐
│                     Installation Layer                       │
│  Firefox RPM from Fedora repositories (installed at build)   │
├─────────────────────────────────────────────────────────────┤
│                       Policy Layer                           │
│  /etc/firefox/policies/policies.json - Enterprise policies   │
├─────────────────────────────────────────────────────────────┤
│                     Extension Layer                          │
│  /usr/lib/firefox/distribution/extensions/ - uBlock Origin   │
├─────────────────────────────────────────────────────────────┤
│                      Profile Layer                           │
│  /etc/skel/.mozilla/firefox/ - Template for new users        │
│  ├── profiles.ini         - Profile configuration            │
│  ├── lifeos.default/      - Default profile directory        │
│  │   ├── user.js          - User preferences                 │
│  │   └── chrome/          - UI customization                 │
│  │       └── userChrome.css - LifeOS visual theme            │
└─────────────────────────────────────────────────────────────┘
```

## Enterprise Policies

The following policies are enforced via `/etc/firefox/policies/policies.json`:

### Privacy & Telemetry

| Policy | Value | Description |
|--------|-------|-------------|
| `DisableTelemetry` | `true` | Blocks all data sent to Mozilla |
| `DisablePocket` | `true` | Disables Pocket integration |
| `DisableFirefoxStudies` | `true` | Blocks Shield studies |
| `DisableFirefoxAccounts` | `true` | Disables Firefox Accounts (no Sync) |
| `DisableFormHistory` | `true` | Doesn't save form history |
| `EnableTrackingProtection` | `true` | Enables Enhanced Tracking Protection |

### User Experience

| Policy | Value | Description |
|--------|-------|-------------|
| `DontCheckDefaultBrowser` | `true` | No default browser prompt |
| `PromptForDownloadLocation` | `false` | Downloads to Downloads folder |
| `OverrideFirstRunPage` | `""` | Skips first-run page |
| `OverridePostUpdatePage` | `""` | Skips post-update page |
| `Homepage.URL` | `about:blank` | Blank homepage |
| `NewTabPage` | `false` | Disables sponsored content |
| `UserMessaging.SkipOnboarding` | `true` | Skips onboarding messages |

### Extensions

| Policy | Value | Description |
|--------|-------|-------------|
| `Extensions.Install` | `["uBlock0@raymondhill.net"]` | Pre-installs uBlock Origin |
| `Extensions.Locked` | `["uBlock0@raymondhill.net"]` | Prevents uninstallation |

### Permissions

| Policy | Value | Description |
|--------|-------|-------------|
| `Location.BlockNewRequests` | `true` | Blocks location requests by default |
| `Camera.BlockNewRequests` | `true` | Blocks camera requests by default |
| `Microphone.BlockNewRequests` | `true` | Blocks microphone requests by default |
| `Notifications.BlockNewRequests` | `true` | Blocks notification requests by default |

### Search

| Policy | Value | Description |
|--------|-------|-------------|
| `SearchEngines.Default` | `DuckDuckGo` | Privacy-focused default search |
| `SearchEngines.Remove` | `Google, Bing, Amazon, eBay` | Removes tracking-heavy engines |

## User Preferences

Settings in `/etc/skel/.mozilla/firefox/lifeos.default/user.js` are preferences (not enforced):

### Wayland & Hardware Acceleration

```javascript
// Wayland native rendering
user_pref("widget.wayland-dmabuf-vaapi.enabled", true);

// Hardware acceleration
user_pref("layers.acceleration.enabled", true);
user_pref("gfx.webrender.all", true);

// VA-API video decoding
user_pref("media.ffmpeg.vaapi.enabled", true);
```

### Privacy Enhancements

```javascript
// Resist fingerprinting
user_pref("privacy.resistFingerprinting", true);

// DNS over HTTPS
user_pref("network.trr.mode", 2);
user_pref("network.trr.uri", "https://dns.quad9.net/dns-query");

// WebRTC leak protection
user_pref("media.peerconnection.ice.default_address_only", true);

// Disable prefetching
user_pref("network.predictor.enabled", false);
user_pref("network.dns.disablePrefetch", true);
```

### UI Preferences

```javascript
// Dark theme
user_pref("layout.css.prefers-color-scheme.content-override", 0);

// Compact UI
user_pref("browser.uidensity", 1);

// Smooth scrolling
user_pref("general.smoothScroll", true);
```

## Visual Theme

The `userChrome.css` applies LifeOS design tokens to Firefox's internal UI:

### Color Palette

| Token | Color | Usage |
|-------|-------|-------|
| `--lifeos-primary` | `#0f4c75` | Primary accent color |
| `--lifeos-accent` | `#3282b8` | Secondary accent, focus rings |
| `--lifeos-surface` | `#16213e` | Tab bar, sidebars, menus |
| `--lifeos-background` | `#1a1a2e` | Main window background |
| `--lifeos-text` | `#e8e8e8` | Primary text |
| `--lifeos-text-muted` | `#a0a0a0` | Secondary text |

### Styled Components

- **Tab Bar**: Dark surface with hover/active states
- **URL Bar**: Rounded with focus glow in accent color
- **Bookmarks Bar**: Matches tab bar styling
- **Menus & Popups**: Rounded corners with shadows
- **Buttons**: Hover states with subtle backgrounds
- **Notifications**: Color-coded (info/warning/error)

## Wayland Support

Firefox runs natively on Wayland via:

1. **Environment Variable**: `MOZ_ENABLE_WAYLAND=1` set in `/etc/profile.d/firefox-wayland.sh`
2. **Desktop Entry**: `/usr/share/applications/firefox-lifeos.desktop` with `--name=firefox-wayland`

Benefits of Wayland native:

- Better HiDPI support
- Proper per-monitor scaling
- No X11 overhead
- Native touchpad gestures
- Better security (no X11 keylogging)

## Verifying Installation

### Check Policies

1. Open Firefox
2. Navigate to `about:policies`
3. Verify all policies are active (green checkmarks)

### Check Extensions

1. Open Firefox
2. Navigate to `about:addons`
3. Verify uBlock Origin is installed and cannot be disabled

### Check Wayland Mode

```bash
# Check if Wayland is enabled
echo $MOZ_ENABLE_WAYLAND

# Check Firefox window type
xprop WM_CLASS | grep -i firefox
# Should show "firefox-wayland"
```

### Run Test Script

```bash
# Run the comprehensive test suite
./tests/firefox/firefox_hardened_tests.sh
```

## Customization

### Adding Custom Preferences

Edit `/etc/skel/.mozilla/firefox/lifeos.default/user.js` to add user preferences:

```javascript
// Custom preference
user_pref("my.custom.preference", "value");
```

**Note**: Preferences in `user.js` can be changed by users. For enforced settings, modify `policies.json`.

### Modifying Visual Theme

Edit `/etc/skel/.mozilla/firefox/lifeos.default/chrome/userChrome.css`:

```css
/* Custom tab color */
.tabbrowser-tab[selected="true"] {
  background-color: var(--lifeos-primary) !important;
}
```

### Adding Extensions

To add more distributed extensions:

1. Download the `.xpi` file from AMO
2. Add to `/usr/lib/firefox/distribution/extensions/`
3. Update `policies.json` to include in `Extensions.Install` and `Extensions.Locked`

## Troubleshooting

### Firefox not using Wayland

```bash
# Verify environment variable
cat /etc/profile.d/firefox-wayland.sh

# Source it manually
source /etc/profile.d/firefox-wayland.sh

# Restart Firefox
```

### Policies not applying

```bash
# Check policy file exists
test -f /etc/firefox/policies/policies.json && echo "OK"

# Validate JSON syntax
python3 -c "import json; json.load(open('/etc/firefox/policies/policies.json'))"
```

### uBlock Origin missing

```bash
# Check extension file
ls -la /usr/lib/firefox/distribution/extensions/uBlock0@raymondhill.net.xpi
```

### Theme not applying

1. Verify `toolkit.legacyUserProfileCustomizations.stylesheets` is `true` (default in user.js)
2. Check userChrome.css exists in profile's chrome directory
3. Restart Firefox

## Files Reference

| File | Purpose |
|------|---------|
| `/etc/firefox/policies/policies.json` | Enterprise policies |
| `/usr/lib/firefox/distribution/extensions/uBlock0@raymondhill.net.xpi` | uBlock Origin extension |
| `/etc/skel/.mozilla/firefox/profiles.ini` | Profile configuration template |
| `/etc/skel/.mozilla/firefox/lifeos.default/user.js` | User preferences template |
| `/etc/skel/.mozilla/firefox/lifeos.default/chrome/userChrome.css` | Visual theme template |
| `/etc/profile.d/firefox-wayland.sh` | Wayland environment variable |
| `/usr/share/applications/firefox-lifeos.desktop` | Desktop entry with Wayland flags |
