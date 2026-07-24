// Proves the OTA APK download now runs in the BACKGROUND, driven by an
// app-level updates listener on the kept-alive notifier — not by an awaited
// call tied to the Updates screen. Concretely:
//  * starting a download ENQUEUES (via ApkDownloadService.startDownload); it
//    does NOT reset+await a convenience download,
//  * a progress event advances notifier state even though no screen is pumped
//    (i.e. "navigating away" cannot stop it — the listener lives on the
//    provider, not the widget),
//  * a complete event verifies the APK, records its path, clears progress, and
//    posts the "ready" notification (payload routes to /settings/updates),
//  * a second start while a download is active ATTACHES (no restart, progress
//    preserved),
//  * a verification failure on complete surfaces an error and no APK path.
// Uses a FakeApkDownloadService with a controllable updates stream — no
// background_downloader platform channel.
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';
import 'package:lifeos/features/app_update/presentation/app_update_notifier.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';

import '../support/fakes.dart';

const _manifest = AppManifest(
  versionCode: 12,
  versionName: '1.4.0',
  apkFilename: 'lifeos-1.4.0-12.apk',
  sha256: 'abc',
  sizeBytes: 150000000,
  notes: '',
  publishedAt: '',
);

({
  ProviderContainer container,
  FakeApkDownloadService download,
  FakeUpdateNotifications notes,
  FakeApkInstaller installer,
}) _harness() {
  final download = FakeApkDownloadService();
  final notes = FakeUpdateNotifications();
  final installer = FakeApkInstaller();
  final c = ProviderContainer(
    overrides: [
      appUpdateInitialStatusProvider.overrideWithValue(const UpdateAvailable(manifest: _manifest)),
      appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo(code: 10, name: '1.0.0')),
      appUpdatePreferencesProvider.overrideWithValue(FakeAppUpdatePreferences()),
      updateNotificationsProvider.overrideWithValue(notes),
      apkDownloadServiceProvider.overrideWithValue(download),
      apkInstallerProvider.overrideWithValue(installer),
    ],
  );
  addTearDown(c.dispose);
  addTearDown(download.dispose);
  return (container: c, download: download, notes: notes, installer: installer);
}

void main() {
  test('downloadUpdate enqueues (startDownload) and seeds progress', () async {
    final h = _harness();
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);

    await notifier.downloadUpdate();

    expect(h.download.startCalls, 1);
    expect(h.container.read(appUpdateNotifierProvider).downloadProgress, 0);
  });

  test('a background progress event advances state with NO screen pumped', () async {
    final h = _harness();
    // Instantiating the notifier registers the app-level updates listener.
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);
    await notifier.downloadUpdate();

    h.download.emitProgress(0.42);
    await pumpEventQueue();

    // Progress landed purely through the provider-level listener — the exact
    // path a user "leaving the Updates screen" would take.
    expect(h.container.read(appUpdateNotifierProvider).downloadProgress, 0.42);
  });

  test('a complete event verifies, records the APK, clears progress, notifies', () async {
    final h = _harness();
    h.download.apkPath = '/data/app_updates/lifeos-update.apk';
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);
    await notifier.downloadUpdate();
    h.download.emitProgress(0.9);
    await pumpEventQueue();

    h.download.emitComplete();
    await pumpEventQueue();

    final state = h.container.read(appUpdateNotifierProvider);
    expect(h.download.verifiedPath, '/data/app_updates/lifeos-update.apk');
    expect(state.downloadedApkPath, '/data/app_updates/lifeos-update.apk');
    expect(state.downloadProgress, 1);
    expect(h.notes.readyShown, ['1.4.0'], reason: 'posts the "ready" notification');
  });

  test('startUpdate leaves installPending so the complete event auto-installs', () async {
    final h = _harness();
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);

    await notifier.startUpdate(); // download in flight, install pending
    expect(h.installer.installCalls, 0);

    h.download.emitComplete();
    await pumpEventQueue();

    // The listener saw installPending on complete and launched the installer.
    expect(h.installer.installCalls, 1);
    expect(h.installer.installedPath, isNotNull);
  });

  test('a second start while active ATTACHES — no restart, progress preserved', () async {
    final h = _harness();
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);
    await notifier.downloadUpdate();
    h.download.emitProgress(0.55);
    await pumpEventQueue();

    // Simulate re-entering the flow (e.g. onAppResumed/auto-download) with a
    // download already running: startDownload reports it attached.
    h.download.alreadyRunning = true;
    await notifier.downloadUpdate();

    expect(h.download.startCalls, 2, reason: 'attempted, but attached not restarted');
    expect(h.container.read(appUpdateNotifierProvider).downloadProgress, 0.55,
        reason: 'progress must NOT reset to zero on re-entry');
  });

  test('a failed status event surfaces an error and no APK path', () async {
    final h = _harness();
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);
    await notifier.downloadUpdate();

    h.download.emitStatus(TaskStatus.failed);
    await pumpEventQueue();

    final state = h.container.read(appUpdateNotifierProvider);
    expect(state.error, isNotNull);
    expect(state.downloadedApkPath, isNull);
    expect(state.downloadProgress, isNull);
  });

  test('a verification failure on complete errors and keeps no APK path', () async {
    final h = _harness();
    h.download.verifyThrows = true;
    final notifier = h.container.read(appUpdateNotifierProvider.notifier);
    await notifier.downloadUpdate();

    h.download.emitComplete();
    await pumpEventQueue();

    final state = h.container.read(appUpdateNotifierProvider);
    expect(state.error, isNotNull);
    expect(state.downloadedApkPath, isNull);
  });
}
