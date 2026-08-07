/// The literal text of each platform's login registration, as pure values.
///
/// ── THE RULE THAT OUTRANKS EVERYTHING ELSE HERE ──────────────────────────
/// The command MUST point at a path that survives an update.
///
/// `tools/install-linux.sh` installs the applications-menu entry with
/// `Exec=$CURRENT_LINK/bundle/lifeos %U` and says why in a comment: it points
/// at the `current` symlink so the entry keeps working across upgrades. The
/// login entry has to follow that precedent exactly. If it pointed at
/// `/opt/lifeos/releases/<version>/…`, `prune_old_releases` would delete that
/// directory two updates later and LifeOS would simply stop starting one day —
/// no error, no log, nothing to connect the symptom to the cause. That is the
/// worst failure this feature can have, so it is refused at the point of
/// writing and not merely avoided by convention: [buildXdgAutostartEntry] and
/// its siblings THROW on a versioned path.
library;

/// Raised when something tried to register a versioned executable path for
/// login. Not a warning: the entry is not written.
class VersionedAutostartPathException implements Exception {
  const VersionedAutostartPathException(this.path);

  final String path;

  String get message =>
      'Refusing to register "$path" to start at login: it contains a version '
      'in the path, so the next update would delete it and LifeOS would stop '
      'starting with nothing to explain why. Register the stable path instead '
      '(on Linux, /opt/lifeos/current/bundle/lifeos).';

  @override
  String toString() => 'VersionedAutostartPathException: $message';
}

/// A path segment that is nothing but a version: `10420`, `1.4.2`, `v2.0`, or
/// a name ending in one, with or without an extension (`LifeOS-2.0.0`,
/// `LifeOS-1.4.2.app`).
final RegExp _versionSegment = RegExp(
  r'^(v?\d+(\.\d+)*|.+[-_]v?\d+(\.\d+)+(\.[A-Za-z]+)?)$',
  caseSensitive: false,
);

/// Whether [path] carries a version, and therefore dies on the next update.
///
/// Whole segments only. `/opt/lifeos3/current/bundle/lifeos` is a product name
/// that happens to contain a digit, not a release directory, and treating it
/// as one would refuse a perfectly stable install.
bool looksLikeVersionedPath(String path) {
  for (final segment in path.split(RegExp(r'[/\\]'))) {
    if (segment.isEmpty) continue;
    if (segment == 'releases') return true;
    if (_versionSegment.hasMatch(segment)) return true;
  }
  return false;
}

/// Whether a rendered entry/command contains a versioned path anywhere.
/// Used by tests and by the read-back guard, so the rule is checked against
/// the bytes that were actually produced rather than against the input.
bool entryContainsVersionedPath(String rendered) => rendered
    .split('\n')
    .where((line) => line.startsWith('Exec=') || line.contains('<string>'))
    .any(looksLikeVersionedPath);

String _requireStable(String execPath) {
  if (looksLikeVersionedPath(execPath)) {
    throw VersionedAutostartPathException(execPath);
  }
  return execPath;
}

/// Quotes a path for a `.desktop` `Exec=` line only when it needs it.
/// Unquoted where possible so the produced file stays byte-comparable with the
/// one `install-linux.sh` writes, which is what makes the two easy to diff.
String _quoteForExec(String value) =>
    value.contains(' ') ? '"$value"' : value;

/// The XDG autostart entry (Linux). Written to
/// `$XDG_CONFIG_HOME/autostart/lifeos.desktop`.
String buildXdgAutostartEntry({
  required String execPath,
  required List<String> arguments,
}) {
  final exec = [
    _quoteForExec(_requireStable(execPath)),
    ...arguments,
  ].join(' ');
  // No `%U`: nothing is being opened. A login launch takes no file arguments,
  // and leaving the placeholder in would only invite a desktop environment to
  // substitute something unexpected.
  return '''
[Desktop Entry]
Type=Application
Name=LifeOS
Comment=Start LifeOS in the background when you log in
Exec=$exec
Icon=lifeos
Terminal=false
StartupWMClass=lifeos
StartupNotify=false
X-GNOME-Autostart-enabled=true
''';
}

/// Whether a `.desktop` entry found on disk is switched ON.
///
/// Both "off" spellings are honoured because both are written by real tools:
/// GNOME Tweaks and KDE's autostart panel set `Hidden=true` rather than
/// deleting the file, and GNOME also understands
/// `X-GNOME-Autostart-enabled=false`. Reporting either as ON would be a toggle
/// that lies about the state of the machine.
bool xdgEntryIsEnabled(String contents) {
  for (final raw in contents.split('\n')) {
    final line = raw.trim();
    final lower = line.toLowerCase();
    if (lower == 'hidden=true') return false;
    if (lower == 'x-gnome-autostart-enabled=false') return false;
  }
  return true;
}

/// The macOS LaunchAgent plist (DESIGNED, not yet wired — no `macos/` runner).
///
/// No `KeepAlive`: that would relaunch LifeOS the instant the user picks
/// "Quit LifeOS" from the tray menu, which would turn the only way out of the
/// app into a no-op.
String buildMacosLaunchAgentPlist({
  required String execPath,
  required List<String> arguments,
}) {
  final programArguments = [
    _requireStable(execPath),
    ...arguments,
  ].map((a) => '    <string>${_escapeXml(a)}</string>').join('\n');

  return '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.lifeos.lifeos</string>
  <key>ProgramArguments</key>
  <array>
$programArguments
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''';
}

String _escapeXml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// The command line for the Windows HKCU Run value (DESIGNED, not yet wired —
/// no `windows/` runner).
///
/// Always quoted: `C:\Program Files\…` is the normal install location, and an
/// unquoted path with a space is the classic Windows privilege-escalation
/// footgun.
String buildWindowsRunCommand({
  required String execPath,
  required List<String> arguments,
}) =>
    ['"${_requireStable(execPath)}"', ...arguments].join(' ');
