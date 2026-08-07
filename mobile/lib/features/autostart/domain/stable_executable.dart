/// Which command the login entry should run.
///
/// `Platform.resolvedExecutable` is NOT the answer, and this is the subtle
/// part of the whole feature. It resolves symlinks, so on a real install it
/// reports `/opt/lifeos/releases/<versionCode>/bundle/lifeos` — precisely the
/// versioned path that `prune_old_releases` deletes two updates later. Writing
/// that into the login entry would break autostart silently on a future
/// update.
///
/// So the stable path is RECOVERED rather than read: take each stable entry
/// point the installer maintains, resolve it, and keep the first one that
/// leads back to the binary this process actually is. That check also answers
/// the "is this an installed copy at all?" question for free — under
/// `flutter run` nothing resolves to the build directory, and the answer is a
/// loud refusal.
library;

import 'login_autostart.dart';

/// The stable entry points `tools/install-linux.sh` maintains, most canonical
/// first.
///
///   * `/opt/lifeos/current/bundle/lifeos` is exactly what
///     `install_desktop_entry` writes into `Exec=` (`$CURRENT_LINK/bundle/…`),
///     and `$CURRENT_LINK` is re-pointed on every update.
///   * `/usr/local/bin/lifeos` is `$LAUNCHER_LINK`, a symlink to the same
///     thing. Kept as a fallback for an install where the launcher survived
///     but the prefix moved.
///
/// Neither contains a version. A test pins that.
const List<String> linuxStableExecutableCandidates = [
  '/opt/lifeos/current/bundle/lifeos',
  '/usr/local/bin/lifeos',
];

/// The stable path that leads to [runningExecutable].
///
/// [resolveRealPath] answers the fully-resolved target of a candidate, or
/// `null` when it does not exist. Injected so this is provable without a
/// filesystem.
///
/// Throws [LoginAutostartUnavailableException] when no candidate leads here.
/// There are two realistic causes and the message names both, because they
/// have different fixes: this is a development build (run the installer), or
/// the tarball was unpacked by hand somewhere else (run the installer).
String resolveStableExecutablePath({
  required String runningExecutable,
  required List<String> candidates,
  required String? Function(String candidate) resolveRealPath,
}) {
  for (final candidate in candidates) {
    // A candidate that resolves SOMEWHERE ELSE is not merely useless, it is
    // dangerous: two installs on one machine, or a symlink left behind by an
    // uninstall, would register a different binary to start at login. Skipped,
    // never used.
    if (resolveRealPath(candidate) == runningExecutable) return candidate;
  }
  throw LoginAutostartUnavailableException(
    'LifeOS is not running from an installed copy, so it cannot register '
    'itself to start at login: none of ${candidates.join(", ")} points at '
    '$runningExecutable. Install it with tools/install-linux.sh first — '
    'registering this path would leave a login entry for a directory that '
    'disappears on the next update or `flutter clean`.',
  );
}
