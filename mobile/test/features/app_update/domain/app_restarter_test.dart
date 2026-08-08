// "Deberia en automatico cerrar y abrir la aplicacion, ya que la estoy
// instalando."
//
// He pressed the install button. Applying the update IS the thing he asked
// for; telling him to close and reopen LifeOS himself is handing back a job he
// already delegated. So after a CONFIRMED install the app relaunches itself.
//
// Everything that touches the process is behind this port, for the obvious
// reason: a test that really ran it would kill the test runner.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/app_restarter.dart';
import 'package:lifeos/features/autostart/domain/stable_executable.dart';

void main() {
  test('the relaunch path is the STABLE symlink, never a versioned one', () {
    // Same trap `stable_executable.dart` documents: the updater has just
    // repointed `current` at the NEW release, and a versioned path would
    // either relaunch the old build or point at a directory `prune_old_releases`
    // deletes two updates later.
    expect(stableDesktopExecutablePath, linuxStableExecutableCandidates.first);
    expect(RegExp(r'/releases/\d').hasMatch(stableDesktopExecutablePath), isFalse);
    expect(stableDesktopExecutablePath, '/opt/lifeos/current/bundle/lifeos');
  });

  test('it launches the new binary DETACHED and only then leaves', () async {
    final launched = <String>[];
    var exited = 0;
    final restarter = DetachedProcessAppRestarter(
      startDetached: (path) async => launched.add(path),
      exitProcess: () => exited++,
    );

    await restarter.restart();

    expect(launched, [stableDesktopExecutablePath]);
    expect(exited, 1);
  });

  test('a launch that fails does NOT kill the running app', () async {
    // Exiting after a failed spawn would leave the user with no LifeOS at all
    // — strictly worse than the update they were already missing.
    var exited = 0;
    final restarter = DetachedProcessAppRestarter(
      startDetached: (_) async => throw const AppRestartException('nope'),
      exitProcess: () => exited++,
    );

    await expectLater(restarter.restart(), throwsA(isA<AppRestartException>()));
    expect(exited, 0);
  });
}
