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
import 'package:lifeos/features/app_update/domain/desktop_update_watcher.dart';
import 'package:lifeos/features/app_update/domain/installed_release.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/features/app_update/domain/update_status.dart';
import 'package:lifeos/features/app_update/presentation/app_update_providers.dart';
import 'package:lifeos/features/app_update/presentation/app_updates_screen.dart';

class _RecordingTrigger implements DesktopUpdateTrigger {
  int calls = 0;

  @override
  Future<void> requestUpdate() async => calls++;

  @override
  Future<bool> isRequestPending() async => false;
}

/// Scripted outcome watcher — this suite is about what the SCREEN says for
/// each observed outcome, so the outcome is handed to it directly.
class _ScriptedWatcher implements DesktopUpdateWatcher {
  _ScriptedWatcher(this.outcome);
  DesktopUpdateOutcome outcome;

  @override
  Future<DesktopUpdateOutcome> awaitOutcome(InstalledRelease? baseline) async =>
      outcome;
}

class _FixedReader implements InstalledReleaseReader {
  const _FixedReader(this.release);
  final InstalledRelease? release;

  @override
  Future<InstalledRelease?> read() async => release;
}

const _installed = InstalledRelease(versionCode: 773, versionName: '0.9.17');
const _landed = InstalledRelease(versionCode: 793, versionName: '0.9.21');

const _manifest = AppManifest(
  versionCode: 771,
  versionName: '0.9.19',
  apkFilename: '',
  sha256: 'abc',
  sizeBytes: 57642149,
  notes: 'Avatar nativo',
  publishedAt: '',
);

Future<void> _pump(
  WidgetTester tester,
  String os, {
  required _RecordingTrigger trigger,
  DesktopUpdateOutcome? outcome,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      hostOperatingSystemProvider.overrideWithValue(os),
      desktopUpdateTriggerProvider.overrideWithValue(trigger),
      desktopUpdateWatcherProvider.overrideWithValue(_ScriptedWatcher(
          outcome ?? DesktopUpdateOutcome.notApplied(_installed))),
      installedReleaseReaderProvider
          .overrideWithValue(const _FixedReader(_installed)),
      appRestarterProvider.overrideWithValue(null),
      desktopRestartGraceProvider.overrideWithValue(Duration.zero),
      appUpdateInitialStatusProvider
          .overrideWithValue(const UpdateAvailable(manifest: _manifest)),
    ],
    // The screen's outcome messages come from the ARB files, and the user's UI
    // is Spanish — so the Spanish locale is what these assertions read.
    child: const MaterialApp(
      locale: Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppUpdatesScreen(),
    ),
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
  });

  testWidgets('a CONFIRMED install is what earns the success message',
      (tester) async {
    await _pump(
      tester,
      'linux',
      trigger: _RecordingTrigger(),
      outcome: DesktopUpdateOutcome.applied(_landed),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Actualizar ahora'));
    await tester.pumpAndSettle();

    expect(find.textContaining('0.9.21'), findsWidgets);
    expect(find.textContaining('se instaló correctamente'), findsOneWidget);
  });

  testWidgets('an update that did NOT land never says "instalada"',
      (tester) async {
    // THE DEFECT, as the user met it: two failed updates, two green
    // confirmations. The screen now names the version he is still on.
    await _pump(
      tester,
      'linux',
      trigger: _RecordingTrigger(),
      outcome: DesktopUpdateOutcome.notApplied(_installed),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Actualizar ahora'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No pude confirmar'), findsOneWidget);
    expect(find.textContaining('0.9.17'), findsWidgets);
    expect(find.textContaining('se instaló correctamente'), findsNothing);
    expect(find.textContaining('Actualización solicitada'), findsNothing,
        reason: 'the old message restated the request as if it were a result');
  });

  testWidgets('a trigger nobody consumed points at the missing updater units',
      (tester) async {
    await _pump(
      tester,
      'linux',
      trigger: _RecordingTrigger(),
      outcome: DesktopUpdateOutcome.notWatched(_installed),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Actualizar ahora'));
    await tester.pumpAndSettle();

    expect(find.textContaining('install-linux.sh'), findsOneWidget);
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
