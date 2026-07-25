// Proves the OTA integrity fixes around manifest changes and dropped
// completions:
//  * a downloaded+verified APK is BOUND to the manifest it was verified
//    against — when the server republishes (new versionCode/sha), check()
//    invalidates the stale binding so the NEW APK is downloaded, and
//    startUpdate() never hands the old file to the installer;
//  * a download completion that arrives while state.status is no longer
//    UpdateAvailable (a concurrent check hit a network blip → UpdateUnknown)
//    RE-CHECKS and still verifies + records the APK — never a silent drop;
//  * if the re-check still cannot resolve a manifest, a user-visible error is
//    surfaced instead of a frozen progress bar.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/data/app_update_service.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';
import 'package:lifeos/features/app_update/presentation/app_update_notifier.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';

import '../support/fakes.dart';

const _v12 = AppManifest(
  versionCode: 12,
  versionName: '1.4.0',
  apkFilename: 'lifeos-1.4.0-12.apk',
  sha256: 'aaa',
  sizeBytes: 150000000,
  notes: '',
  publishedAt: '',
);

const _v13 = AppManifest(
  versionCode: 13,
  versionName: '1.5.0',
  apkFilename: 'lifeos-1.5.0-13.apk',
  sha256: 'bbb',
  sizeBytes: 150000000,
  notes: '',
  publishedAt: '',
);

/// Update-check stub whose result a test can flip mid-flow (server republish).
class _MutableUpdateService extends AppUpdateService {
  _MutableUpdateService(this.result) : super(Dio(), FakeAppVersionInfo());
  UpdateStatus result;
  int checks = 0;
  @override
  Future<UpdateStatus> checkForUpdate() async {
    checks++;
    return result;
  }
}

({
  ProviderContainer container,
  FakeApkDownloadService download,
  FakeUpdateNotifications notes,
  FakeApkInstaller installer,
  _MutableUpdateService service,
}) _harness({UpdateStatus initial = const UpdateAvailable(manifest: _v12)}) {
  final download = FakeApkDownloadService();
  final notes = FakeUpdateNotifications();
  final installer = FakeApkInstaller();
  final service = _MutableUpdateService(initial);
  final c = ProviderContainer(
    overrides: [
      appUpdateInitialStatusProvider.overrideWithValue(initial),
      appUpdateServiceProvider.overrideWithValue(service),
      appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo(code: 10, name: '1.0.0')),
      appUpdatePreferencesProvider.overrideWithValue(FakeAppUpdatePreferences()),
      updateNotificationsProvider.overrideWithValue(notes),
      apkDownloadServiceProvider.overrideWithValue(download),
      apkInstallerProvider.overrideWithValue(installer),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(download.dispose);
  return (container: c, download: download, notes: notes, installer: installer, service: service);
}

void main() {
  test('a republished manifest INVALIDATES the previously downloaded APK', () async {
    final h = _harness();
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);

    // v12 downloads + verifies → path bound to v12.
    await notifier.downloadUpdate();
    h.download.emitComplete();
    await pumpEventQueue();
    expect(h.container.read(appUpdateNotifierProvider).downloadedApkPath, isNotNull);

    // Server republishes v13 while the session is alive.
    h.service.result = const UpdateAvailable(manifest: _v13);
    await notifier.check();

    final state = h.container.read(appUpdateNotifierProvider);
    expect(state.status, isA<UpdateAvailable>());
    expect((state.status as UpdateAvailable).versionCode, 13);
    expect(state.downloadedApkPath, isNull,
        reason: 'the v12 file was never verified against the v13 sha');

    // The flow is NOT wedged: downloading again actually re-enqueues.
    final before = h.download.startCalls;
    await notifier.downloadUpdate();
    expect(h.download.startCalls, before + 1);
  });

  test('startUpdate() after a republish DOWNLOADS v13 — never installs the v12 file', () async {
    final h = _harness();
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);

    await notifier.downloadUpdate();
    h.download.emitComplete();
    await pumpEventQueue();

    h.service.result = const UpdateAvailable(manifest: _v13);
    await notifier.check();

    await notifier.startUpdate();

    expect(h.installer.installCalls, 0,
        reason: 'the stale v12 APK must not reach the installer as "v13"');
    expect(h.download.startCalls, greaterThanOrEqualTo(2),
        reason: 'the v13 APK is downloaded instead');
  });

  test('an unchanged manifest on re-check KEEPS the verified APK (no churn)', () async {
    final h = _harness();
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);

    await notifier.downloadUpdate();
    h.download.emitComplete();
    await pumpEventQueue();

    await notifier.check(); // same v12 manifest
    expect(h.container.read(appUpdateNotifierProvider).downloadedApkPath, isNotNull);
  });

  test('a completion while status is UpdateUnknown RE-CHECKS and still verifies', () async {
    final h = _harness();
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);
    await notifier.downloadUpdate();

    // Mid-download, a resume-time check hits a network blip → UpdateUnknown
    // overwrites the manifest that lived only in state.status.
    h.service.result = const UpdateUnknown();
    await notifier.check();
    expect(h.container.read(appUpdateNotifierProvider).status, isA<UpdateUnknown>());

    // The server is reachable again by the time the download completes.
    h.service.result = const UpdateAvailable(manifest: _v12);
    h.download.emitComplete();
    await pumpEventQueue();

    final state = h.container.read(appUpdateNotifierProvider);
    expect(state.downloadedApkPath, isNotNull,
        reason: 'the completion must be recovered, not silently dropped');
    expect(state.error, isNull);
    expect(h.notes.readyShown, isNotEmpty);
  });

  test('a completion that STILL cannot resolve a manifest surfaces an error', () async {
    final h = _harness();
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);
    await notifier.startUpdate(); // installPending = true

    h.service.result = const UpdateUnknown();
    await notifier.check();
    h.download.emitComplete(); // re-check also yields UpdateUnknown
    await pumpEventQueue();

    final state = h.container.read(appUpdateNotifierProvider);
    expect(state.downloadedApkPath, isNull);
    expect(state.error, isNotNull, reason: 'never a silent wedge');
    expect(state.downloadProgress, isNull, reason: 'no frozen bar');
    expect(state.installPending, isFalse);
  });
}
