// Proves AppUpdateNotifier.check() wiring: an available update sets the state,
// posts a local notification when the notify pref is ON (and records the
// de-dup marker), stays silent when notify is OFF, and does not notify twice
// for the same build on the same day. Uses a stub AppUpdateService (subclass)
// + fakes; no Dio/plugins are exercised.
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

class _StubUpdateService extends AppUpdateService {
  _StubUpdateService(this.result) : super(Dio(), FakeAppVersionInfo());
  final UpdateStatus result;
  @override
  Future<UpdateStatus> checkForUpdate() async => result;
}

const _manifest = AppManifest(
  versionCode: 12,
  versionName: '1.4.0',
  apkFilename: 'lifeos-1.4.0-12.apk',
  sha256: 'abc',
  sizeBytes: 150000000,
  notes: '',
  publishedAt: '',
);

ProviderContainer _container({
  required UpdateStatus stub,
  required FakeAppUpdatePreferences prefs,
  required FakeUpdateNotifications notes,
}) {
  final c = ProviderContainer(
    overrides: [
      appUpdateServiceProvider.overrideWithValue(_StubUpdateService(stub)),
      appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo(code: 10, name: '1.0.0')),
      appUpdatePreferencesProvider.overrideWithValue(prefs),
      updateNotificationsProvider.overrideWithValue(notes),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('check() surfaces UpdateAvailable and notifies once when notify is ON', () async {
    final prefs = FakeAppUpdatePreferences(initial: const AppUpdateSettings(notify: true));
    final notes = FakeUpdateNotifications();
    final c = _container(stub: const UpdateAvailable(manifest: _manifest), prefs: prefs, notes: notes);

    await c.read(appUpdateNotifierProvider.notifier).check();

    expect(c.read(appUpdateNotifierProvider).status, isA<UpdateAvailable>());
    expect(notes.shown, ['1.4.0']);
    expect(prefs.notifiedCode, 12);
  });

  test('check() does not notify when notify is OFF', () async {
    final prefs = FakeAppUpdatePreferences(initial: const AppUpdateSettings(notify: false));
    final notes = FakeUpdateNotifications();
    final c = _container(stub: const UpdateAvailable(manifest: _manifest), prefs: prefs, notes: notes);

    await c.read(appUpdateNotifierProvider.notifier).check();

    expect(notes.shown, isEmpty);
  });

  test('check() does not re-notify for the same build on the same day', () async {
    final prefs = FakeAppUpdatePreferences(initial: const AppUpdateSettings(notify: true))
      ..notifiedCode = 12
      ..notifiedDay = _todayKey();
    final notes = FakeUpdateNotifications();
    final c = _container(stub: const UpdateAvailable(manifest: _manifest), prefs: prefs, notes: notes);

    await c.read(appUpdateNotifierProvider.notifier).check();

    expect(notes.shown, isEmpty);
  });

  test('check() reports UpToDate without notifying', () async {
    final prefs = FakeAppUpdatePreferences();
    final notes = FakeUpdateNotifications();
    final c = _container(
      stub: const UpToDate(currentVersionName: '1.0.0', currentVersionCode: 10),
      prefs: prefs,
      notes: notes,
    );

    await c.read(appUpdateNotifierProvider.notifier).check();
    expect(c.read(appUpdateNotifierProvider).status, isA<UpToDate>());
    expect(notes.shown, isEmpty);
  });
}

String _todayKey() {
  final n = DateTime.now();
  return '${n.year.toString().padLeft(4, '0')}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}
