/// How the desktop app updates itself with NO terminal and NO privilege.
///
/// THE PROBLEM. The app runs as the user. The release lives in `/opt/lifeos`,
/// which only root may replace. So the app cannot install its own update — and
/// it must not try: a GUI app that pops a sudo prompt is teaching the user to
/// type their root password into whatever asks, which is the exact habit that
/// gets people compromised.
///
/// THE HANDSHAKE. `tools/install-linux.sh` installs `lifeos-updater.path`, a
/// systemd unit whose entire job is to watch one file and start the updater
/// service when it appears. The app touches that file. systemd — already root,
/// already running, already audited — does the rest. The app's total privilege
/// requirement is one `write()` into a world-writable directory.
///
/// This is the "por medio de la app" half of the requirement. The other half is
/// `lifeos-updater.timer`, which updates hourly whether or not the app is even
/// running. Between them the user never opens a terminal again.
///
/// WHY IT FAILS LOUDLY. If the units are not installed (someone unpacked the
/// tarball by hand), touching the file achieves nothing — no watcher, no
/// updater, ever. Silently "succeeding" would leave the user waiting for an
/// update nobody is going to perform, which is precisely the quiet degradation
/// this repo forbids. So a missing trigger directory throws, and the UI says
/// what is wrong.
library;

import 'dart:io';

/// Thrown when the update cannot be requested because the system-side updater
/// is not present. Carries a message meant for the user, not a stack trace.
class DesktopUpdateUnavailableException implements Exception {
  const DesktopUpdateUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Requests that the system update LifeOS.
abstract class DesktopUpdateTrigger {
  /// Ask for an update to run. Returns once the request is REGISTERED — not
  /// once the update has finished; the updater runs as a separate root process
  /// and will restart the app's release out from under this one.
  Future<void> requestUpdate();

  /// Whether a previously made request is STILL sitting there unconsumed.
  ///
  /// `lifeos-updater.path` deletes the file when it fires, so this is the app's
  /// only unprivileged proof that something is — or is not — listening. Still
  /// pending seconds after the request means the units are not installed or not
  /// running, which is a different failure with a different fix than "the
  /// update ran and failed". `DesktopUpdateWatcher` uses it to tell those two
  /// apart instead of reporting one generic timeout for both.
  Future<bool> isRequestPending();
}

/// The real trigger: creates the file `lifeos-updater.path` watches.
class SystemdPathUpdateTrigger implements DesktopUpdateTrigger {
  const SystemdPathUpdateTrigger({String? triggerPath})
      : _triggerPath = triggerPath ?? defaultTriggerPath;

  /// The path in the shipped unit's `PathExists=`. Duplicated here rather than
  /// read from the unit because the app must not depend on parsing systemd
  /// config; a test pins the two together instead.
  static const String defaultTriggerPath =
      '/var/lib/lifeos/trigger/update-requested';

  final String _triggerPath;

  @override
  Future<bool> isRequestPending() async {
    try {
      return await File(_triggerPath).exists();
    } catch (_) {
      // Cannot tell. Answering "pending" would accuse systemd of not watching
      // on no evidence, so the uncertain answer is the quiet one and the
      // watcher's timeout still reports honestly.
      return false;
    }
  }

  @override
  Future<void> requestUpdate() async {
    final file = File(_triggerPath);
    // The installer creates this directory mode 1777 precisely so the app,
    // running unprivileged, can drop the flag. Its absence means the updater
    // units were never installed — there is no watcher to notice the file.
    if (!await file.parent.exists()) {
      throw const DesktopUpdateUnavailableException(
        'El actualizador del sistema no está instalado, así que LifeOS no '
        'puede actualizarse solo. Reinstalá con install-linux.sh para '
        'habilitarlo.',
      );
    }
    try {
      // Empty file: its EXISTENCE is the whole signal. The updater service
      // removes it when it runs, so a second request works.
      await file.create(recursive: false);
    } on FileSystemException catch (e) {
      throw DesktopUpdateUnavailableException(
        'No se pudo pedir la actualización: ${e.osError?.message ?? e.message}',
      );
    }
  }
}
