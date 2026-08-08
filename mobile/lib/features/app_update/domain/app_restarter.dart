/// Relaunching LifeOS into the version that was just installed.
///
/// "Deberia en automatico cerrar y abrir la aplicacion, ya que la estoy
/// instalando." He is right, and the reason matters more than the convenience:
/// he PRESSED the install button, so applying the update is the thing he asked
/// for. Telling him to close and reopen the app himself is handing back a job
/// he already delegated.
///
/// THE PATH IS THE STABLE SYMLINK, and this is the same trap
/// `features/autostart/domain/stable_executable.dart` documents at length.
/// `Platform.resolvedExecutable` reports
/// `/opt/lifeos/releases/<versionCode>/bundle/lifeos` — the release we are
/// currently running, i.e. the OLD one, which is precisely what we must not
/// relaunch. `/opt/lifeos/current/bundle/lifeos` is repointed by the installer
/// in the same atomic swap that lands the new release, so it is the only path
/// that means "the version that was just installed".
///
/// WHAT IS BEHIND THE PORT AND WHY. Spawning a process and calling `exit()` are
/// both things a test must never really do — one would litter the CI box with
/// orphaned GUI processes, the other would kill the test runner mid-suite. So
/// the two OS calls are injected, exactly like `TrayIconHost` and
/// `LoginAutostart` do for their own OS-level integrations.
///
/// DESKTOP ONLY. On Android and iOS the OS owns the app lifecycle; there is
/// nothing to relaunch and no process we are allowed to end. The provider
/// answers null there and the notifier treats that as "nothing to do", not as
/// a failure.
library;

import 'dart:io';

/// Thrown when the relaunch could not be performed. Carries a message meant
/// for the user.
class AppRestartException implements Exception {
  const AppRestartException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The port.
abstract class AppRestarter {
  /// Launch the freshly installed build detached, then end this process.
  ///
  /// Throws [AppRestartException] when the new binary could not be started —
  /// in which case this process MUST still be alive.
  Future<void> restart();
}

/// The stable entry point the installer repoints on every update. Identical by
/// contract to `linuxStableExecutableCandidates.first`; a test pins the two
/// together so neither can be renamed alone.
const String stableDesktopExecutablePath = '/opt/lifeos/current/bundle/lifeos';

Future<void> _startDetachedProcess(String executable) async {
  try {
    await Process.start(
      executable,
      const <String>[],
      // Fully detached: no stdio pipes held open, no parent-child link. The
      // new LifeOS must survive this process ending a moment later.
      mode: ProcessStartMode.detached,
    );
  } on ProcessException catch (e) {
    throw AppRestartException(
      'No se pudo abrir la nueva versión de LifeOS ($executable): '
      '${e.message}',
    );
  }
}

void _exitProcess() => exit(0);

/// The real restarter.
class DetachedProcessAppRestarter implements AppRestarter {
  const DetachedProcessAppRestarter({
    this.executablePath = stableDesktopExecutablePath,
    this.startDetached = _startDetachedProcess,
    this.exitProcess = _exitProcess,
  });

  final String executablePath;

  /// The two OS calls, injected. Public because that IS the seam: a test that
  /// really ran them would orphan a GUI process on the CI box and kill the
  /// test runner mid-suite.
  final Future<void> Function(String executable) startDetached;
  final void Function() exitProcess;

  @override
  Future<void> restart() async {
    // ORDER IS THE CONTRACT. Start first, exit only after the start returned
    // without throwing. Exiting on a failed spawn would leave the user with no
    // LifeOS at all — strictly worse than the update he was already missing.
    await startDetached(executablePath);
    exitProcess();
  }
}
