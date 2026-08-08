/// What is REALLY installed in `/opt/lifeos`, read from the machine.
///
/// WHY THIS EXISTS. The desktop updater is a root systemd service in another
/// process. The app cannot see its exit code and cannot read the journal, so
/// after asking for an update it has exactly one honest way to learn whether
/// anything happened: look at what the installer left behind.
///
/// `tools/install-linux.sh` leaves two durable facts, and this reads both:
///
///   * `$PREFIX/manifest.json` — the published manifest, copied VERBATIM
///     (`cp "$WORKDIR/manifest.json" "$STATE_MANIFEST"`) after the release is
///     staged and the `current` symlink swapped. Mode 0644, so the app reads it
///     unprivileged. It carries `versionCode` AND `versionName`, which is why
///     it is tried first: the user thinks in "0.9.21", not in "793".
///   * `$PREFIX/current` — a symlink to `releases/<versionCode>`, repointed in
///     the same atomic swap. Used as a fallback, and it can only recover the
///     code; the name is then reported as unknown rather than invented.
///
/// NOTE for anyone reading a brief that says otherwise: there is no
/// `/opt/lifeos/VERSION` file. The installer never writes one — verified
/// against `tools/install-linux.sh` and against a live install.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// The release currently installed on this machine.
@immutable
class InstalledRelease {
  const InstalledRelease({required this.versionCode, required this.versionName});

  /// The monotonically increasing build number. This is the field the update
  /// watcher compares; names are for humans.
  final int versionCode;

  /// The human version ("0.9.21"), or empty when only the symlink was readable.
  final String versionName;

  @override
  bool operator ==(Object other) =>
      other is InstalledRelease &&
      other.versionCode == versionCode &&
      other.versionName == versionName;

  @override
  int get hashCode => Object.hash(versionCode, versionName);

  @override
  String toString() => 'InstalledRelease($versionName, $versionCode)';
}

/// Reads the installed release. A port so the update watcher is provable with
/// no `/opt/lifeos` on the machine running the tests.
abstract class InstalledReleaseReader {
  /// The release on disk, or `null` when it cannot be determined.
  ///
  /// `null` is NOT "version 0". A reader that answered 0 for an unreadable
  /// disk would make the very next successful read look like an upgrade, and
  /// the app would announce an install that never happened — the exact class of
  /// lie this whole file exists to prevent.
  Future<InstalledRelease?> read();
}

/// Parse the installer's state manifest. Returns `null` for anything it cannot
/// read with confidence.
InstalledRelease? parseInstalledReleaseManifest(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final code = decoded['versionCode'];
    if (code is! int || code <= 0) return null;
    final name = decoded['versionName'];
    return InstalledRelease(
      versionCode: code,
      versionName: name is String ? name : '',
    );
  } catch (_) {
    return null;
  }
}

/// Recover the versionCode from a `current` symlink target
/// (`/opt/lifeos/releases/793` → 793). `null` when the target is not a release
/// directory — a `.staging-…` leftover must never read as a version.
int? versionCodeFromReleaseLink(String target) {
  final segment = target.split('/').where((s) => s.isNotEmpty).lastOrNull;
  if (segment == null) return null;
  final code = int.tryParse(segment);
  if (code == null || code <= 0) return null;
  return code;
}

/// The production reader: the paths `tools/install-linux.sh` maintains.
class OptLifeosInstalledReleaseReader implements InstalledReleaseReader {
  const OptLifeosInstalledReleaseReader({
    String? manifestPath,
    String? currentLinkPath,
  })  : _manifestPath = manifestPath ?? defaultManifestPath,
        _currentLinkPath = currentLinkPath ?? defaultCurrentLinkPath;

  /// `$STATE_MANIFEST` in the installer. Pinned by a test on both sides.
  static const String defaultManifestPath = '/opt/lifeos/manifest.json';

  /// `$CURRENT_LINK` in the installer.
  static const String defaultCurrentLinkPath = '/opt/lifeos/current';

  final String _manifestPath;
  final String _currentLinkPath;

  @override
  Future<InstalledRelease?> read() async {
    final fromManifest = await _readManifest();
    if (fromManifest != null) return fromManifest;
    return _readSymlink();
  }

  Future<InstalledRelease?> _readManifest() async {
    try {
      final file = File(_manifestPath);
      if (!await file.exists()) return null;
      return parseInstalledReleaseManifest(await file.readAsString());
    } catch (_) {
      // Unreadable is indistinguishable from absent for our purposes, and both
      // must degrade to the symlink rather than to a guess.
      return null;
    }
  }

  Future<InstalledRelease?> _readSymlink() async {
    try {
      final link = Link(_currentLinkPath);
      if (!await link.exists()) return null;
      final code = versionCodeFromReleaseLink(await link.target());
      if (code == null) return null;
      // Name deliberately empty: the symlink does not carry one, and inventing
      // "793" as a version name would put a number in front of the user that
      // matches nothing he has ever seen in the release notes.
      return InstalledRelease(versionCode: code, versionName: '');
    } catch (_) {
      return null;
    }
  }
}
