import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/autostart/domain/login_autostart.dart';
import 'package:lifeos/features/autostart/presentation/login_autostart_providers.dart';
import 'package:lifeos/features/autostart/presentation/login_autostart_tile.dart';
import 'package:lifeos/l10n/app_localizations.dart';

/// The toggle itself — "todo desde la app". Not a documented shell command,
/// not a line in a README: a switch in Settings.
class _FakeAutostart implements LoginAutostart {
  _FakeAutostart({this.enabled = false});

  bool enabled;
  Object? writeError;

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<void> setEnabled(bool value) async {
    final error = writeError;
    if (error != null) throw error;
    enabled = value;
  }
}

Future<void> pumpTile(
  WidgetTester tester, {
  required String os,
  LoginAutostart? autostart,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        hostOperatingSystemProvider.overrideWithValue(os),
        loginAutostartPortProvider.overrideWithValue(autostart),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: LoginAutostartTile()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('is ABSENT where the platform has no login autostart',
      (tester) async {
    // Same product rule the tray and the hotkey row already follow: a control
    // that is shown is a control that works.
    await pumpTile(tester, os: 'android');
    expect(find.byType(SwitchListTile), findsNothing);
  });

  testWidgets('shows the real current state, not a remembered one',
      (tester) async {
    await pumpTile(tester, os: 'linux', autostart: _FakeAutostart(enabled: true));

    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value, isTrue);
  });

  testWidgets('flipping it on registers the app for login', (tester) async {
    final fake = _FakeAutostart();
    await pumpTile(tester, os: 'linux', autostart: fake);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(fake.enabled, isTrue);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
  });

  testWidgets('a failure is VISIBLE and the switch stays off', (tester) async {
    final fake = _FakeAutostart()
      ..writeError = const LoginAutostartUnavailableException(
        'LifeOS is not running from an installed copy.',
      );
    await pumpTile(tester, os: 'linux', autostart: fake);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
      reason: 'a switch that shows ON while nothing was written is a lie',
    );
    expect(
      find.textContaining('not running from an installed copy'),
      findsOneWidget,
    );
  });
}
