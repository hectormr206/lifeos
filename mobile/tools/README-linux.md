# LifeOS on Linux desktop

The Flutter app compiles and runs on Linux, and the on-device brain
(`flutter_gemma` + LiteRT) compiles with it — the same model that runs on the
phone. What follows is how to publish and install it, and an honest account of
what does **not** work yet.

**Read [What does not work yet](#what-does-not-work-yet-verified) before you
install.** As of this writing the desktop build is not usable for real work:
the encrypted database has no Linux implementation.

---

## Publishing

```bash
cd mobile
./tools/publish-linux-to-vps.sh "release notes"
```

Mirrors `publish-to-vps.sh`. It:

1. builds `flutter build linux --release` with the OTA dart-defines baked in,
2. packs the bundle, the icon, the systemd units and the installer itself into
   one `.tar.gz`,
3. computes sha256 + size and writes the manifest,
4. uploads to `$VPS_DIR/linux/<arch>/`, **payload first and manifest last**, so
   a half-finished upload never advertises a version that cannot be downloaded,
5. verifies the live endpoint serves the new `versionCode` *and* that the
   tarball itself really is fetchable (a `Range: 0-0` request, not 150 MB).

Config comes from `tools/ota-publish.env`, the same gitignored file the Android
publisher uses. Nothing new to set up.

### Endpoint layout

```
<UPDATE_BASE_URL>/linux/install-linux.sh          arch-independent installer
<UPDATE_BASE_URL>/linux/x64/manifest.json         the manifest
<UPDATE_BASE_URL>/linux/x64/lifeos-linux-x64-<ver>-<code>.tar.gz
```

The manifest mirrors the APK one; `apkFilename` becomes `filename`, and `arch`
is added because a desktop client must refuse a tarball built for another CPU:

```json
{
  "versionCode": 1234,
  "versionName": "0.9.19",
  "filename": "lifeos-linux-x64-0.9.19-1234.tar.gz",
  "sha256": "…64 hex…",
  "sizeBytes": 158000000,
  "arch": "x64",
  "platform": "linux",
  "notes": "abc1234 commit subject",
  "publishedAt": "2026-08-05T12:00:00Z"
}
```

`versionCode` is `git rev-list --count HEAD`, exactly as on Android, so a phone
and a laptop built from the same commit report the same version.

---

## Installing

```bash
curl -fsSL https://<base>/linux/install-linux.sh \
  | sudo sh -s -- --base-url https://<base> --key <UPDATE_ACCESS_KEY>
```

The installer is POSIX `sh`, not bash, so it works where `/bin/sh` is dash or
busybox. It is **distro-agnostic**: it detects the package manager by looking
for the binary that actually exists (`pacman`, `apt-get`, `dnf`, `zypper`,
`apk`, `xbps-install`), falling back to `ID`/`ID_LIKE` from `/etc/os-release`.
CachyOS resolves to `pacman` through `ID_LIKE=arch`.

It **never installs system packages for you**. It probes for the actual shared
objects (SONAMEs are the same everywhere; package names are not) and, if any
are missing, prints the exact command for your distro and stops.

What it does:

| | |
|---|---|
| `/opt/lifeos/releases/<versionCode>/` | the app bundle, ~150 MB per release (2 kept) |
| `/opt/lifeos/current` | symlink to the active release, swapped atomically |
| `/usr/local/bin/lifeos` | command-line launcher |
| `/usr/share/applications/lifeos.desktop` | applications-menu entry |
| `/usr/share/icons/hicolor/512x512/apps/lifeos.png` | icon |
| `/etc/lifeos/update.env` | base URL + access key, mode `0600` |
| `/etc/systemd/system/lifeos-updater.{service,timer,path}` | auto-update |

Other flags: `--update` (quiet upgrade, used by the service), `--uninstall`,
`--force`, `--skip-dep-check`, `--help`.

Re-running is an upgrade in place, and a no-op when already current.

### Safety properties

- The sha256 **and** the byte size are verified before anything is unpacked. A
  mismatch deletes the download and aborts; the installed app is untouched.
- The new release is staged in full under `.staging-*` and only then moved into
  place and the `current` symlink swapped. There is no window where `current`
  points at a partial tree.
- A failed manifest fetch is an **error**, never "you are up to date". A check
  that cannot run fails loudly.
- Everything the target needs ships inside the one artifact whose checksum is
  verified — the installer, the units and the icon included — so nothing is
  fetched separately at install time and nothing can be swapped underneath the
  checksum.
- `--uninstall` removes the app, the units, the launcher and the config. It
  does **not** delete your data in `~/.local/share/com.lifeos.lifeos/` and
  `~/.config/com.lifeos.lifeos/`.

### Runtime dependencies

Required — the app will not start without them:

| SONAME | why | Arch | Debian/Ubuntu | Fedora |
|---|---|---|---|---|
| `libgtk-3.so.0` | the Flutter Linux shell | `gtk3` | `libgtk-3-0` | `gtk3` |
| `libgstreamer-1.0.so.0` | `audioplayers_linux` | `gstreamer` | `libgstreamer1.0-0` | `gstreamer1` |
| `libgstapp-1.0.so.0` | `audioplayers_linux` | `gst-plugins-base-libs` | `libgstreamer-plugins-base1.0-0` | `gstreamer1-plugins-base` |
| `libsecret-1.so.0` | `flutter_secure_storage_linux` | `libsecret` | `libsecret-1-0` | `libsecret` |
| `libayatana-appindicator3.so.1` | `tray_manager` (system-tray icon) | `libayatana-appindicator` | `libayatana-appindicator3-1` | `libayatana-appindicator-gtk3` |

Optional — the app starts, but voice input will not work:

| binary | why | Arch | Debian/Ubuntu |
|---|---|---|---|
| `parecord` | `record_linux` records by launching it | `libpulse` | `pulseaudio-utils` |
| `ffmpeg` | `record_linux` encodes with it | `ffmpeg` | `ffmpeg` |

`libsecret` also needs a **running Secret Service daemon** (gnome-keyring or
kwallet). The library alone stores nothing; without a daemon LifeOS cannot keep
its pairing token between launches. The installer warns when it finds neither.

`libayatana-appindicator3` is **required, not optional**: `tray_manager` sets
`tray_manager_bundled_libraries ""`, so the library is not shipped inside the
release and the dynamic loader fails the whole process at startup if it is
missing. Like libsecret, having the library is not enough — something on the
session bus has to *host* a `StatusNotifierItem`. KDE, Xfce, Cinnamon and most
tray applets do; **GNOME Shell does not by default** and needs the
`gnome-shell-extension-appindicator` extension, which the installer warns about
when it sees `gnome-shell`. If no host answers, LifeOS still runs and says
*"Sin icono en la barra del sistema"* in-app rather than silently showing
nothing.

### Building from source on this box

```bash
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev \
  liblzma-dev libstdc++-12-dev libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev libsecret-1-dev libjsoncpp-dev \
  libayatana-appindicator3-dev
cd mobile && flutter build linux --release
```

If CMake insists on installing into `/usr/local`, the cache is stale:
`rm -rf mobile/build/linux` and build again.

---

## Updates

Automatic, and they survive logout. That is why they are **system** units and
not `--user` units: a user unit dies with the login session, which is exactly
the failure this design avoids.

- `lifeos-updater.timer` — hourly, `Persistent=true` so checks missed while the
  laptop was suspended still run.
- `lifeos-updater.service` — runs `/opt/lifeos/bin/lifeos-install.sh --update`
  as root: fetches the manifest, exits 0 silently if already current, otherwise
  downloads, verifies sha256 and swaps the release in.
- `lifeos-updater.path` — watches `/var/lib/lifeos/trigger/update-requested`
  and starts the service when it appears.

```bash
systemctl status lifeos-updater.timer
sudo systemctl start lifeos-updater.service   # force a check now
journalctl -u lifeos-updater.service -n 50
```

The trigger directory is mode `1777`, so the app — running as the desktop user
— can ask for a check without holding root. That is the whole privilege
boundary: the unprivileged side can only say *"please check now"*, never what
to install or from where. The URL, the key and the sha256 verification all live
on the root side.

### Why not in-app, like Android?

Because on Linux it currently cannot be. `apk_download_service.dart` downloads
through `background_downloader`, which has no Linux implementation, and
`apk_installer.dart` installs through `open_filex` + `permission_handler`,
neither of which has one either. Even if they did, the app runs as the desktop
user and cannot write to `/opt/lifeos`.

So the root-side updater is not a workaround, it is the part that has to exist
regardless. What is still missing to match the phone experience is the in-app
*button*: one line of Dart that creates
`/var/lib/lifeos/trigger/update-requested`. The path unit is already installed
and enabled and works today; **nothing in `lib/` touches that file yet.**

**Known rough edge:** `app_update_service.dart` fetches the manifest with Dio,
which works fine on Linux, so the desktop app *will* show the "update
available" banner. Pressing download then throws `MissingPluginException` from
`background_downloader`. It fails loudly rather than silently, which is the
house rule, but it is still a dead button. Until the banner is gated on
platform, tell the user to ignore it — the timer already installed the update.

---

## What does not work yet (verified)

Verified by inspecting each package under `~/.pub-cache/hosted/pub.dev/`, the
generated `linux/flutter/generated_plugins.cmake` and
`.dart_tool/flutter_build/dart_plugin_registrant.dart` of a real release build
— not by reading pub.dev metadata, which is how an earlier pass of this
analysis got it wrong.

### Broken

| Feature | Package | Status |
|---|---|---|
| **Encrypted database (all persistence)** | `sqflite_sqlcipher` | **No Linux implementation.** No `linux/` folder, no federated `*_linux` package; its pubspec declares android/ios/macos only. |
| All model downloads (brain 2.4 GB, STT, TTS, embeddings) and the in-app update download | `background_downloader` | No Linux implementation. Pubspec declares android/ios only; no `background_downloader_linux` exists. |
| Background task execution (morning briefing while closed) | `workmanager` | No Linux implementation. Endorses `workmanager_android` / `workmanager_apple` only. |
| Scheduled notifications (reminders, daily digest, briefing) | `flutter_local_notifications_linux` | Partial — see below. |
| In-app APK-style install | `open_filex`, `permission_handler` | No Linux implementation. Replaced by the systemd updater. |
| 3D brain view, Axi body view | `webview_flutter` | No Linux implementation. Already guarded by `WebViewPlatform.instance != null`, so these degrade instead of crashing. |

`sqflite_sqlcipher` is the blocking one. The property-graph store
(`lib/core/graph/`) is the app's memory; `openDatabase` will throw
`MissingPluginException` on Linux, so the desktop build launches but cannot
store or read anything. **Do not treat this build as usable yet.** Fixing it
means either a Linux SQLCipher implementation or an FFI backend
(`sqlite3_flutter_libs` + `sqlcipher_flutter_libs`) behind the existing
`local_graph_database.dart` seam.

`workmanager` is already safe: `main.dart` wraps `Workmanager().initialize()`
in a try/catch precisely so a platform without the plugin does not block
startup, and the reminder + generate-on-open fallback stays. Briefings simply
will not generate while the app is closed.

### Partial

**Notifications.** `flutter_local_notifications_linux` **does** exist and *is*
registered (it is Dart-only over D-Bus, so it appears in
`dart_plugin_registrant.dart`, not in `generated_plugins.cmake` — absence from
the CMake list is not evidence of absence). But it implements only `show`,
`cancel` and `cancelAll`. There is **no `zonedSchedule` and no
`periodicallyShow`**, so immediate notifications work and every *scheduled*
one — reminders, the daily digest, the morning briefing — does not.

**Voice input.** `record_linux` exists and its native plugin is in the bundle
(`librecord_linux_plugin.so`), but it does not record in-process: it launches
`parecord` and encodes with `ffmpeg`. Without those two binaries on `PATH`,
recording fails. The installer warns.

### Working

Verified present in the release bundle at
`build/linux/x64/release/bundle/lib/`:

- **On-device brain** — `flutter_gemma` with `libLiteRt.so`, `libLiteRtLm.so`,
  `libGemmaModelConstraintProvider.so`. The same brain as the phone.
- **STT / TTS engines** — `sherpa_onnx_linux` (FFI) with
  `libsherpa-onnx-c-api.so` and `libonnxruntime.so`. The *engines* build; the
  *model downloads* do not, per `background_downloader` above.
- **Audio playback** — `audioplayers_linux`.
- **Secure storage** — `flutter_secure_storage_linux` (needs libsecret + a
  Secret Service daemon).
- **File picker, URL launcher, timezone** — `file_selector_linux`,
  `url_launcher_linux`, `flutter_timezone`.
- **System tray** — `tray_manager` (icon + menu) and `window_manager`
  (show/focus/hide, close-to-tray). Desktop only: neither declares an
  android/ios plugin platform, so nothing is registered on the phone.
- **Version info, paths, preferences** — `package_info_plus`,
  `path_provider`, `shared_preferences` (all Dart-side Linux support).

### No stubs

None of the missing plugins has been stubbed out. A missing implementation
raises `MissingPluginException` at the call site, loudly, with a stack trace
naming the plugin. That is deliberate and matches the standing rule in this
codebase: a check that cannot run must fail loudly, never degrade quietly. A
silent no-op recording button or a notification that is scheduled and never
fires would be far worse than a crash that says exactly what is missing.
