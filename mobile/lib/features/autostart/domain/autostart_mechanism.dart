/// How each desktop asks an application to start at login, and where that
/// registration physically lives.
///
/// Shaped exactly like `features/app_update/domain/update_manifest_path.dart`:
/// every function takes the operating-system NAME as a parameter and answers
/// `null` where the capability does not exist. That is what lets a Linux host
/// assert what the macOS and Windows builds WILL do — long before this repo
/// has a `macos/` or `windows/` runner.
///
/// ── WHAT IS WIRED TODAY ──────────────────────────────────────────────────
/// Linux only. The mechanisms for macOS and Windows are *designed* here (the
/// paths, the key, the file contents — all pure and unit-tested in
/// `autostart_entry.dart`), but there is nothing to run them from: this repo
/// contains `linux/`, `android/` and `web/` and no other runner. Adding one
/// later is then a `flutter create --platforms=macos` plus an implementation
/// of [LoginAutostart] that writes what these functions already describe.
///
/// [loginAutostartIsImplementedOn] is deliberately separate from
/// [supportsLoginAutostart]: "this platform has a mechanism" and "this build
/// can drive it" are different claims, and collapsing them is how a toggle
/// ends up appearing to work while doing nothing.
library;

/// The per-platform registration mechanism.
enum AutostartMechanism {
  /// XDG: a `.desktop` file in `$XDG_CONFIG_HOME/autostart/`.
  ///
  /// Chosen over a systemd user unit on purpose: it is what desktop
  /// environments actually read for GUI apps, it is per-user, it needs no
  /// root, and — the deciding reason — the app can write it itself at runtime,
  /// which is what makes the in-app toggle possible at all.
  xdgDesktopEntry,

  /// macOS: a per-user LaunchAgent plist in `~/Library/LaunchAgents/`.
  launchAgentPlist,

  /// Windows: a value under the per-user `Run` key. HKCU, never HKLM —
  /// machine-wide would need administrator rights, and an unprivileged toggle
  /// is the whole point.
  runRegistryValue,
}

/// The application id LifeOS is known by on the desktops. Matches
/// `linux/CMakeLists.txt`'s `APPLICATION_ID` and the data directories
/// `tools/install-linux.sh` names on uninstall.
const String lifeosApplicationId = 'com.lifeos.lifeos';

/// The mechanism [operatingSystem] uses, or `null` where "start at login" is
/// not a concept the platform has.
///
/// Android and iOS answer null and that is not a shortcoming: apps there are
/// started by the system on demand, and there is no login session to attach
/// to. An unknown platform answers null too — a capability is opt-in per
/// platform, so a future shell shows a smaller, honest UI rather than
/// inheriting a control nobody has verified there.
AutostartMechanism? autostartMechanismFor(String operatingSystem) =>
    switch (operatingSystem) {
      'linux' => AutostartMechanism.xdgDesktopEntry,
      'macos' => AutostartMechanism.launchAgentPlist,
      'windows' => AutostartMechanism.runRegistryValue,
      _ => null,
    };

/// Whether [operatingSystem] has a login-autostart mechanism at all.
bool supportsLoginAutostart(String operatingSystem) =>
    autostartMechanismFor(operatingSystem) != null;

/// Whether THIS BUILD can actually drive that mechanism.
///
/// Linux is implemented (`data/xdg_login_autostart.dart`). macOS and Windows
/// are designed and tested as pure values but have no runner in this repo, so
/// they answer false and the Settings toggle stays absent there rather than
/// shown and inert.
bool loginAutostartIsImplementedOn(String operatingSystem) =>
    operatingSystem == 'linux';

/// `$XDG_CONFIG_HOME/autostart/lifeos.desktop`, falling back to
/// `$HOME/.config` per the XDG Base Directory spec.
///
/// The spec says an unset OR relative `XDG_CONFIG_HOME` must be treated as
/// unset; honouring a relative one would put the entry somewhere relative to
/// whatever directory the process happened to start in, which nobody would
/// ever find.
String xdgAutostartEntryPath({required String home, String? xdgConfigHome}) {
  final configHome = (xdgConfigHome != null &&
          xdgConfigHome.isNotEmpty &&
          xdgConfigHome.startsWith('/'))
      ? xdgConfigHome
      : '$home/.config';
  return '$configHome/autostart/lifeos.desktop';
}

/// The directory part of [xdgAutostartEntryPath]. Split out because it has to
/// be created before the file can be written — a fresh account has no
/// `~/.config/autostart` at all.
String xdgAutostartDirectoryOf(String entryPath) =>
    entryPath.substring(0, entryPath.lastIndexOf('/'));

/// `~/Library/LaunchAgents/com.lifeos.lifeos.plist` (designed, not yet wired).
String macosLaunchAgentPlistPath({required String home}) =>
    '$home/Library/LaunchAgents/$lifeosApplicationId.plist';

/// The per-user Run key (designed, not yet wired).
const String windowsRunRegistryKey =
    r'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run';

/// The value name under [windowsRunRegistryKey].
const String windowsRunValueName = 'LifeOS';
