// Proves the home/settings "update available" banner shows only when an
// update is available and renders nothing otherwise.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/app_update/presentation/update_available_banner.dart';

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

Future<void> _pump(WidgetTester tester, UpdateStatus initial) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appUpdateInitialStatusProvider.overrideWithValue(initial),
        appVersionInfoProvider.overrideWithValue(FakeAppVersionInfo()),
        appUpdatePreferencesProvider.overrideWithValue(FakeAppUpdatePreferences()),
      ],
      child: const MaterialApp(home: Scaffold(body: UpdateAvailableBanner())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the banner when an update is available', (tester) async {
    await _pump(tester, const UpdateAvailable(manifest: _manifest));
    expect(find.text('Nueva versión disponible'), findsOneWidget);
    expect(find.textContaining('1.4.0'), findsOneWidget);
  });

  testWidgets('hides the banner when up to date', (tester) async {
    await _pump(tester, const UpToDate(currentVersionName: '1.4.0', currentVersionCode: 12));
    expect(find.text('Nueva versión disponible'), findsNothing);
  });

  testWidgets('hides the banner when update state is unknown', (tester) async {
    await _pump(tester, const UpdateUnknown());
    expect(find.text('Nueva versión disponible'), findsNothing);
  });
}
