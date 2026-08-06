// What the Updates screen offers depends on which machine it is running on.
//
// The product rule is the user's: hide what a platform cannot do, so each one
// keeps its own superpowers. On desktop there is no APK, no download bar the
// app owns, and no "install unknown apps" grant — the systemd updater does all
// of it as root. Showing those controls would mean showing controls that do
// nothing, which is worse than showing nothing at all.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/app_update/domain/app_manifest.dart';
import 'package:lifeos/features/app_update/domain/desktop_update_trigger.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/app_update/presentation/app_updates_screen.dart';

class _RecordingTrigger implements DesktopUpdateTrigger {
  int calls = 0;

  @override
  Future<void> requestUpdate() async => calls++;
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

Future<void> _pump(WidgetTester tester, String os,
    {required _RecordingTrigger trigger}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      hostOperatingSystemProvider.overrideWithValue(os),
      desktopUpdateTriggerProvider.overrideWithValue(trigger),
      appUpdateInitialStatusProvider
          .overrideWithValue(const UpdateAvailable(manifest: _manifest)),
    ],
    child: const MaterialApp(home: AppUpdatesScreen()),
  ));
  await tester.pump();
}

void main() {
  testWidgets('on Linux, tapping "Actualizar ahora" asks the system updater',
      (tester) async {
    final trigger = _RecordingTrigger();
    await _pump(tester, 'linux', trigger: trigger);

    await tester.tap(find.widgetWithText(FilledButton, 'Actualizar ahora'));
    await tester.pump();

    expect(trigger.calls, 1);
    expect(find.textContaining('Actualización solicitada'), findsOneWidget);
  });

  testWidgets('the desktop screen says updates also happen on their own',
      (tester) async {
    // The user asked for updates that need no terminal. Saying so on the
    // screen is what makes that promise checkable by them, not just by us.
    await _pump(tester, 'linux', trigger: _RecordingTrigger());

    expect(find.textContaining('se actualiza solo'), findsOneWidget);
  });

  testWidgets('the APK-only auto-download switch is ABSENT on desktop',
      (tester) async {
    await _pump(tester, 'linux', trigger: _RecordingTrigger());

    expect(find.text('Descargar automáticamente'), findsNothing);
  });

  testWidgets('Android still shows the APK controls', (tester) async {
    // The regression guard: the phone holds the real data.
    await _pump(tester, 'android', trigger: _RecordingTrigger());

    expect(find.text('Descargar automáticamente'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Actualizar ahora'), findsOneWidget);
    expect(find.textContaining('se actualiza solo'), findsNothing);
  });
}
