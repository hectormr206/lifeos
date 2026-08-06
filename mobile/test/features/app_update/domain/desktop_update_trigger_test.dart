// How the app updates itself on Linux WITHOUT the user opening a terminal.
//
// The app runs as the user; the release lives in /opt/lifeos and only root may
// replace it. The app must therefore never try to install anything itself, and
// it must never shell out to sudo — a GUI app asking for a root password is
// exactly the shape of thing users should refuse.
//
// Instead the installer ships `lifeos-updater.path`, a systemd unit watching
// one file. The app touches that file; systemd runs the updater as root. The
// app needs no privilege at all, and the whole handshake is one write().
//
// The failure mode that matters: the units are NOT installed (someone copied
// the binary by hand, or ran the tarball without the installer). Per the
// repo's fail-loudly rule this must SAY SO, not pretend the update was
// requested and leave the user waiting forever for something nobody is going
// to do.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/desktop_update_trigger.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('lifeos-trigger-'));
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('requesting an update creates the file systemd watches', () async {
    final trigger =
        SystemdPathUpdateTrigger(triggerPath: '${temp.path}/update-requested');

    await trigger.requestUpdate();

    expect(File('${temp.path}/update-requested').existsSync(), isTrue,
        reason: 'lifeos-updater.path fires on PathExists — no file, no update');
  });

  test('asking twice is harmless', () async {
    // Two taps on "Actualizar ahora" must not be an error; systemd de-dupes.
    final trigger =
        SystemdPathUpdateTrigger(triggerPath: '${temp.path}/update-requested');

    await trigger.requestUpdate();
    await trigger.requestUpdate();

    expect(File('${temp.path}/update-requested').existsSync(), isTrue);
  });

  test('a missing trigger directory FAILS LOUDLY', () async {
    // The updater units are not installed. Silently "succeeding" here would
    // leave the user staring at a spinner for an update that will never run.
    final trigger = SystemdPathUpdateTrigger(
        triggerPath: '${temp.path}/nonexistent/update-requested');

    await expectLater(
      trigger.requestUpdate(),
      throwsA(isA<DesktopUpdateUnavailableException>()),
    );
  });

  test('the exception explains what to do, not just that it broke', () async {
    final trigger = SystemdPathUpdateTrigger(
        triggerPath: '${temp.path}/nonexistent/update-requested');

    try {
      await trigger.requestUpdate();
      fail('expected DesktopUpdateUnavailableException');
    } on DesktopUpdateUnavailableException catch (e) {
      expect(e.message, contains('actualizador'));
      expect(e.toString(), isNot(contains('Instance of')));
    }
  });

  test('the default path is the one the installed unit actually watches',
      () {
    // Contract shared with tools/systemd/lifeos-updater.path. If either side
    // moves, this fails rather than the button quietly doing nothing.
    expect(SystemdPathUpdateTrigger.defaultTriggerPath,
        '/var/lib/lifeos/trigger/update-requested');
  });
}
