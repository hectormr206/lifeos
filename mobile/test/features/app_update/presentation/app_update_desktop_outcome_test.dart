// What the app says after asking systemd to update it — and what it does next.
//
// TWO DEFECTS, both found by using the thing:
//
//   1. It reported success for something that failed. "Actualización
//      solicitada… se aplica la próxima vez que abras LifeOS" was printed the
//      instant the trigger file was created, and printed identically on the two
//      consecutive runs where the update really failed (HTTP 403, no access key
//      saved). A request was presented as a result. Now the app WATCHES the
//      disk and reports what actually happened.
//
//   2. A user-initiated update should apply itself. He pressed the button; the
//      update is the thing he asked for, so LifeOS relaunches into it instead
//      of asking him to close and reopen the app himself. ONLY when he pressed
//      the button — a background check that happens to find a new version must
//      never take the window away mid-sentence.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/app_restarter.dart';
import 'package:lifeos/features/app_update/domain/desktop_update_trigger.dart';
import 'package:lifeos/features/app_update/domain/desktop_update_watcher.dart';
import 'package:lifeos/features/app_update/domain/installed_release.dart';
import 'package:lifeos/features/app_update/domain/update_initiator.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';
import 'package:lifeos/features/app_update/presentation/app_update_notifier.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';

import '../support/fakes.dart';

class _FakeTrigger implements DesktopUpdateTrigger {
  int requests = 0;
  Exception? throws;

  @override
  Future<void> requestUpdate() async {
    requests++;
    if (throws != null) throw throws!;
  }

  @override
  Future<bool> isRequestPending() async => false;
}

class _FakeWatcher implements DesktopUpdateWatcher {
  _FakeWatcher(this.outcome);

  DesktopUpdateOutcome outcome;
  InstalledRelease? sawBaseline;
  int calls = 0;

  @override
  Future<DesktopUpdateOutcome> awaitOutcome(InstalledRelease? baseline) async {
    calls++;
    sawBaseline = baseline;
    return outcome;
  }
}

class _FakeRestarter implements AppRestarter {
  int restarts = 0;
  Object? throws;

  @override
  Future<void> restart() async {
    restarts++;
    if (throws != null) throw throws!;
  }
}

class _FixedReader implements InstalledReleaseReader {
  _FixedReader(this.release);
  InstalledRelease? release;

  @override
  Future<InstalledRelease?> read() async => release;
}

const _manifest = AppManifest(
  versionCode: 793,
  versionName: '0.9.21',
  apkFilename: '',
  sha256: 'abc',
  sizeBytes: 57384190,
  notes: 'Reinicio automático',
  publishedAt: '',
);

const _before = InstalledRelease(versionCode: 773, versionName: '0.9.17');
const _after = InstalledRelease(versionCode: 793, versionName: '0.9.21');

ProviderContainer _container({
  required _FakeTrigger trigger,
  required _FakeWatcher watcher,
  required _FakeRestarter restarter,
  String os = 'linux',
  InstalledRelease? installed = _before,
}) {
  final container = ProviderContainer(overrides: [
    hostOperatingSystemProvider.overrideWithValue(os),
    desktopUpdateTriggerProvider.overrideWithValue(trigger),
    desktopUpdateWatcherProvider.overrideWithValue(watcher),
    appRestarterProvider.overrideWithValue(restarter),
    installedReleaseReaderProvider.overrideWithValue(_FixedReader(installed)),
    // No visible pause in tests; the grace only exists so the human sees the
    // "reiniciando…" state before the window goes.
    desktopRestartGraceProvider.overrideWithValue(Duration.zero),
    appUpdateInitialStatusProvider
        .overrideWithValue(const UpdateAvailable(manifest: _manifest)),
    appUpdatePreferencesProvider.overrideWithValue(FakeAppUpdatePreferences()),
    appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo()),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('the outcome the app reports is the one that happened', () {
    test('a confirmed install names the version that landed', () async {
      final trigger = _FakeTrigger();
      final watcher = _FakeWatcher(DesktopUpdateOutcome.applied(_after));
      final restarter = _FakeRestarter();
      final container = _container(
          trigger: trigger, watcher: watcher, restarter: restarter);

      await container
          .read(appUpdateNotifierProvider.notifier)
          .startUpdate(initiator: UpdateInitiator.user);

      final state = container.read(appUpdateNotifierProvider);
      expect(state.desktopUpdatePhase, DesktopUpdatePhase.restarting);
      expect(state.desktopUpdateVersionName, '0.9.21');
      expect(watcher.sawBaseline, _before,
          reason: 'the version installed BEFORE is what "changed" is measured '
              'against');
    });

    test('an update that never landed is NOT reported as installed', () async {
      // The exact defect. Two failed updates, two green confirmations.
      final trigger = _FakeTrigger();
      final watcher = _FakeWatcher(DesktopUpdateOutcome.notApplied(_before));
      final restarter = _FakeRestarter();
      final container = _container(
          trigger: trigger, watcher: watcher, restarter: restarter);

      await container
          .read(appUpdateNotifierProvider.notifier)
          .startUpdate(initiator: UpdateInitiator.user);

      final state = container.read(appUpdateNotifierProvider);
      expect(state.desktopUpdatePhase, DesktopUpdatePhase.notApplied);
      expect(state.desktopUpdateVersionName, '0.9.17',
          reason: 'the honest line names the version STILL installed');
      expect(restarter.restarts, 0,
          reason: 'restarting into an update that did not happen is theatre');
    });

    test('a trigger nobody consumed is reported as its own failure', () async {
      final trigger = _FakeTrigger();
      final watcher = _FakeWatcher(DesktopUpdateOutcome.notWatched(_before));
      final restarter = _FakeRestarter();
      final container = _container(
          trigger: trigger, watcher: watcher, restarter: restarter);

      await container
          .read(appUpdateNotifierProvider.notifier)
          .startUpdate(initiator: UpdateInitiator.user);

      expect(container.read(appUpdateNotifierProvider).desktopUpdatePhase,
          DesktopUpdatePhase.notWatched);
      expect(restarter.restarts, 0);
    });

    test('a missing system updater still fails loudly and watches nothing',
        () async {
      final trigger = _FakeTrigger()
        ..throws = const DesktopUpdateUnavailableException(
            'El actualizador del sistema no está instalado.');
      final watcher = _FakeWatcher(DesktopUpdateOutcome.applied(_after));
      final restarter = _FakeRestarter();
      final container = _container(
          trigger: trigger, watcher: watcher, restarter: restarter);

      await container
          .read(appUpdateNotifierProvider.notifier)
          .startUpdate(initiator: UpdateInitiator.user);

      final state = container.read(appUpdateNotifierProvider);
      expect(state.error, contains('actualizador'));
      expect(state.desktopUpdatePhase, DesktopUpdatePhase.idle);
      expect(watcher.calls, 0, reason: 'nothing was requested, so nothing to watch');
      expect(restarter.restarts, 0);
    });
  });

  group('restarting into the new version', () {
    test('a USER-initiated update relaunches the app', () async {
      final restarter = _FakeRestarter();
      final container = _container(
        trigger: _FakeTrigger(),
        watcher: _FakeWatcher(DesktopUpdateOutcome.applied(_after)),
        restarter: restarter,
      );

      await container
          .read(appUpdateNotifierProvider.notifier)
          .startUpdate(initiator: UpdateInitiator.user);

      expect(restarter.restarts, 1,
          reason: 'he pressed install; applying it is what he asked for');
    });

    test('a BACKGROUND update never takes the window away', () async {
      // The guard that matters. Someone is mid-sentence in the chat and the
      // hourly timer lands an update: killing the process there would destroy
      // work he never asked us to touch.
      final restarter = _FakeRestarter();
      final container = _container(
        trigger: _FakeTrigger(),
        watcher: _FakeWatcher(DesktopUpdateOutcome.applied(_after)),
        restarter: restarter,
      );

      await container
          .read(appUpdateNotifierProvider.notifier)
          .startUpdate(initiator: UpdateInitiator.background);

      expect(restarter.restarts, 0);
      expect(container.read(appUpdateNotifierProvider).desktopUpdatePhase,
          DesktopUpdatePhase.applied,
          reason: 'still tell him it landed — just do not act on it for him');
    });

    test('a relaunch that fails says so and leaves the app running', () async {
      final restarter = _FakeRestarter()
        ..throws = const AppRestartException('no such file');
      final container = _container(
        trigger: _FakeTrigger(),
        watcher: _FakeWatcher(DesktopUpdateOutcome.applied(_after)),
        restarter: restarter,
      );

      await container
          .read(appUpdateNotifierProvider.notifier)
          .startUpdate(initiator: UpdateInitiator.user);

      final state = container.read(appUpdateNotifierProvider);
      expect(state.desktopUpdatePhase, DesktopUpdatePhase.applied,
          reason: 'the update DID land; only the relaunch did not');
      expect(state.error, isNotNull);
    });

    test('no restarter on this platform is not an error', () async {
      // Android and iOS own app lifecycle; there is nothing to relaunch.
      final container = ProviderContainer(overrides: [
        hostOperatingSystemProvider.overrideWithValue('linux'),
        desktopUpdateTriggerProvider.overrideWithValue(_FakeTrigger()),
        desktopUpdateWatcherProvider
            .overrideWithValue(_FakeWatcher(DesktopUpdateOutcome.applied(_after))),
        appRestarterProvider.overrideWithValue(null),
        installedReleaseReaderProvider.overrideWithValue(_FixedReader(_before)),
        desktopRestartGraceProvider.overrideWithValue(Duration.zero),
        appUpdateInitialStatusProvider
            .overrideWithValue(const UpdateAvailable(manifest: _manifest)),
        appUpdatePreferencesProvider.overrideWithValue(FakeAppUpdatePreferences()),
        appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo()),
      ]);
      addTearDown(container.dispose);

      await container
          .read(appUpdateNotifierProvider.notifier)
          .startUpdate(initiator: UpdateInitiator.user);

      final state = container.read(appUpdateNotifierProvider);
      expect(state.desktopUpdatePhase, DesktopUpdatePhase.applied);
      expect(state.error, isNull);
    });
  });

  test('Android never asks systemd and never restarts itself', () async {
    // The regression guard: the phone carries the real data.
    final trigger = _FakeTrigger();
    final restarter = _FakeRestarter();
    final container = _container(
      trigger: trigger,
      watcher: _FakeWatcher(DesktopUpdateOutcome.applied(_after)),
      restarter: restarter,
      os: 'android',
    );

    await container
        .read(appUpdateNotifierProvider.notifier)
        .startUpdate(initiator: UpdateInitiator.user);

    expect(trigger.requests, 0);
    expect(restarter.restarts, 0);
  });
}
