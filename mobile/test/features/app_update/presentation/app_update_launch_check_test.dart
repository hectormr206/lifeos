// Proves the launch-time update check now runs WITHOUT pairing (the update
// source is a public URL, not the paired engine): watching
// appUpdateLaunchCheckProvider fires maybeAutoCheck even when the device is
// unpaired, and still honors the auto-check preference.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/data/app_update_service.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/app_update_preferences.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';
import 'package:lifeos/features/app_update/presentation/app_update_notifier.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';

import '../support/fakes.dart';

class _CountingUpdateService extends AppUpdateService {
  _CountingUpdateService(this.result) : super(Dio(), FakeAppVersionInfo());
  final UpdateStatus result;
  int calls = 0;
  @override
  Future<UpdateStatus> checkForUpdate() async {
    calls++;
    return result;
  }
}

const _manifest = AppManifest(
  versionCode: 12,
  versionName: '1.4.0',
  apkFilename: 'lifeos-1.4.0-12.apk',
  sha256: 'abc',
  sizeBytes: 1,
  notes: '',
  publishedAt: '',
);

void main() {
  test('launch check runs the update check without pairing when auto-check is ON', () async {
    final service = _CountingUpdateService(const UpdateAvailable(manifest: _manifest));
    final c = ProviderContainer(
      overrides: [
        appUpdateServiceProvider.overrideWithValue(service),
        appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo(code: 10)),
        appUpdatePreferencesProvider.overrideWithValue(
          FakeAppUpdatePreferences(initial: const AppUpdateSettings(autoCheck: true)),
        ),
        updateNotificationsProvider.overrideWithValue(FakeUpdateNotifications()),
      ],
    );
    addTearDown(c.dispose);

    // No pairing set up at all — the provider must still fire the check.
    c.read(appUpdateLaunchCheckProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(service.calls, 1);
    expect(c.read(appUpdateNotifierProvider).status, isA<UpdateAvailable>());
  });

  test('launch check honors auto-check OFF (no check fired)', () async {
    final service = _CountingUpdateService(const UpdateAvailable(manifest: _manifest));
    final c = ProviderContainer(
      overrides: [
        appUpdateServiceProvider.overrideWithValue(service),
        appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo(code: 10)),
        appUpdatePreferencesProvider.overrideWithValue(
          FakeAppUpdatePreferences(initial: const AppUpdateSettings(autoCheck: false)),
        ),
        updateNotificationsProvider.overrideWithValue(FakeUpdateNotifications()),
      ],
    );
    addTearDown(c.dispose);

    c.read(appUpdateLaunchCheckProvider);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(service.calls, 0);
  });
}
