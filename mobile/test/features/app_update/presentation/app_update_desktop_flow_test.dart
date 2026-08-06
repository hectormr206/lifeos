// "Actualizar ahora" on the desktop must not run the Android flow.
//
// On the phone the app downloads an APK and hands it to the system package
// installer. On Linux there is no APK and no installer to hand it to: the
// release lives in /opt/lifeos, owned by root, and the app runs as the user.
// Driving the Android path there would download a phone package the laptop
// cannot execute and then fail at an installer that does not exist.
//
// What the desktop does instead is ask systemd, by creating the file the
// installed `lifeos-updater.path` unit watches. That is the whole point of the
// user's requirement — the update happens THROUGH THE APP, with no terminal
// and no sudo prompt.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/desktop_update_trigger.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';
import 'package:lifeos/features/app_update/presentation/app_update_notifier.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';

class _RecordingTrigger implements DesktopUpdateTrigger {
  int calls = 0;
  Exception? throws;

  @override
  Future<void> requestUpdate() async {
    calls++;
    if (throws != null) throw throws!;
  }
}

const _manifest = AppManifest(
  versionCode: 771,
  versionName: '0.9.19',
  apkFilename: '',
  sha256: 'abc',
  sizeBytes: 57642149,
  notes: 'Avatar nativo',
  publishedAt: '',
);

ProviderContainer _container(String os, _RecordingTrigger trigger) {
  final container = ProviderContainer(overrides: [
    hostOperatingSystemProvider.overrideWithValue(os),
    desktopUpdateTriggerProvider.overrideWithValue(trigger),
    appUpdateInitialStatusProvider
        .overrideWithValue(const UpdateAvailable(manifest: _manifest)),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('on Linux, "Actualizar ahora" asks systemd — it downloads no APK',
      () async {
    final trigger = _RecordingTrigger();
    final container = _container('linux', trigger);

    await container.read(appUpdateNotifierProvider.notifier).startUpdate();

    expect(trigger.calls, 1);
    final state = container.read(appUpdateNotifierProvider);
    expect(state.downloadProgress, isNull,
        reason: 'the systemd updater downloads the tarball, not the app');
    expect(state.error, isNull);
  });

  test('the user is told the update was requested, not left guessing',
      () async {
    // The updater replaces /opt/lifeos and restarts; from inside the app the
    // only honest thing to report is that the request went through.
    final trigger = _RecordingTrigger();
    final container = _container('linux', trigger);

    await container.read(appUpdateNotifierProvider.notifier).startUpdate();

    expect(container.read(appUpdateNotifierProvider).desktopUpdateRequested,
        isTrue);
  });

  test('a missing system updater surfaces the reason — it does not spin',
      () async {
    final trigger = _RecordingTrigger()
      ..throws = const DesktopUpdateUnavailableException(
          'El actualizador del sistema no está instalado.');
    final container = _container('linux', trigger);

    await container.read(appUpdateNotifierProvider.notifier).startUpdate();

    final state = container.read(appUpdateNotifierProvider);
    expect(state.error, contains('actualizador'));
    expect(state.desktopUpdateRequested, isFalse,
        reason: 'nothing was requested, so claiming otherwise would be a lie');
  });

  test('Android is untouched: it never asks systemd', () async {
    // The phone carries the real data. This is the regression guard.
    final trigger = _RecordingTrigger();
    final container = _container('android', trigger);

    await container.read(appUpdateNotifierProvider.notifier).startUpdate();

    expect(trigger.calls, 0);
  });
}
