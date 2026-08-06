// Proves the "Actualizaciones de la app" screen renders the installed +
// available versions (with notes), the "Buscar actualizaciones" action, the
// three preference toggles reflecting persisted values, and — when an update
// is available — the download action. Providers are overridden with fakes;
// the initial status is seeded via appUpdateInitialStatusProvider so no real
// network check runs.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/app_update_preferences.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/app_update/presentation/app_updates_screen.dart';

import '../support/fakes.dart';

const _manifest = AppManifest(
  versionCode: 12,
  versionName: '1.4.0',
  apkFilename: 'lifeos-1.4.0-12.apk',
  sha256: 'abc',
  sizeBytes: 150000000,
  notes: 'Mejoras de rendimiento',
  publishedAt: '2026-07-20T00:00:00+00:00',
);

Future<void> _pump(
  WidgetTester tester, {
  required UpdateStatus initial,
  AppUpdateSettings settings = const AppUpdateSettings(),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // This screen's APK controls are Android's. Pinned because the suite
        // runs on Linux, where they are deliberately absent — see
        // app_updates_screen_desktop_test.dart for that surface.
        hostOperatingSystemProvider.overrideWithValue('android'),
        appUpdateInitialStatusProvider.overrideWithValue(initial),
        appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo(code: 10, name: '1.0.0')),
        appUpdatePreferencesProvider
            .overrideWithValue(FakeAppUpdatePreferences(initial: settings)),
        updateNotificationsProvider.overrideWithValue(FakeUpdateNotifications()),
      ],
      child: const MaterialApp(home: AppUpdatesScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders installed + available versions with notes and actions', (tester) async {
    await _pump(tester, initial: const UpdateAvailable(manifest: _manifest));

    expect(find.text('Actualizaciones de la app'), findsOneWidget);
    expect(find.textContaining('1.0.0'), findsWidgets); // installed version
    expect(find.textContaining('1.4.0'), findsWidgets); // available version
    expect(find.textContaining('Mejoras de rendimiento'), findsOneWidget);
    expect(find.text('Buscar actualizaciones'), findsOneWidget);
    expect(find.text('Actualizar ahora'), findsOneWidget);
  });

  testWidgets('renders the three toggles reflecting persisted values', (tester) async {
    await _pump(
      tester,
      initial: const UpToDate(currentVersionName: '1.0.0', currentVersionCode: 10),
      settings: const AppUpdateSettings(autoCheck: true, notify: false, autoDownload: true),
    );

    expect(find.text('Buscar automáticamente'), findsOneWidget);
    expect(find.text('Notificar'), findsOneWidget);
    expect(find.text('Descargar automáticamente'), findsOneWidget);

    final switches = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
    expect(switches, hasLength(3));
    expect(switches[0].value, isTrue); // auto-check
    expect(switches[1].value, isFalse); // notify
    expect(switches[2].value, isTrue); // auto-download

    // No update available -> no update action.
    expect(find.text('Actualizar ahora'), findsNothing);
  });

  testWidgets('toggling a switch persists via the notifier', (tester) async {
    await _pump(
      tester,
      initial: const UpToDate(currentVersionName: '1.0.0', currentVersionCode: 10),
    );

    // Flip "Notificar" off.
    await tester.tap(find.text('Notificar'));
    await tester.pumpAndSettle();

    final switches = tester.widgetList<SwitchListTile>(find.byType(SwitchListTile)).toList();
    expect(switches[1].value, isFalse);
  });
}
