// Proves the "Zona horaria" screen: AUTOMATIC is the default (switch ON, shows
// the detected zone read-only), turning it off reveals the searchable IANA
// picker, and tapping a zone pins it as a manual override — all against fakes,
// no platform channels.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/timezone/device_timezone.dart';
import 'package:lifeos/core/timezone/timezone_preference.dart';
import 'package:lifeos/core/timezone/timezone_providers.dart';
import 'package:lifeos/features/settings/presentation/timezone_settings_notifier.dart';
import 'package:lifeos/features/settings/presentation/timezone_settings_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePrefs implements TimezonePreferences {
  _FakePrefs(this._pref);
  TimezonePreference _pref;
  @override
  Future<TimezonePreference> load() async => _pref;
  @override
  Future<void> save(TimezonePreference preference) async => _pref = preference;
}

class _FakeDetector implements DeviceTimezoneDetector {
  _FakeDetector(this._id);
  final String? _id;
  @override
  Future<String?> currentZoneId() async => _id;
}

Widget _app() => const MaterialApp(
      home: TimezoneSettingsScreen(),
      locale: Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );

Future<void> _pump(WidgetTester tester, {required TimezonePreference initial}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      timezonePreferencesProvider.overrideWithValue(_FakePrefs(initial)),
      deviceTimezoneDetectorProvider.overrideWithValue(_FakeDetector('America/Mexico_City')),
    ],
    child: _app(),
  ));
  final container = ProviderScope.containerOf(tester.element(find.byType(TimezoneSettingsScreen)));
  await container.read(timezoneSettingsNotifierProvider.notifier).ready;
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // The re-arm path touches the digest/briefing preferences; keep their
    // schedules DISABLED so re-arming is a cheap no-op with no platform channel.
    SharedPreferences.setMockInitialValues({
      'daily_digest_schedule_enabled': false,
      'morning_briefing_schedule_enabled': false,
    });
  });

  testWidgets('AUTOMATIC by default: switch ON, shows the detected zone', (tester) async {
    await _pump(tester, initial: const TimezonePreference.automatic());

    final sw = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(sw.value, isTrue);
    expect(find.text('Detectada: America/Mexico_City'), findsOneWidget);
    // No picker while automatic.
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('turning AUTOMATIC off reveals the searchable picker and pins a zone',
      (tester) async {
    await _pump(tester, initial: const TimezonePreference.automatic());

    // Toggle the switch off.
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    // The picker (search field + zone list) is now visible.
    expect(find.byType(TextField), findsOneWidget);

    // Narrow the list, then pick a zone.
    await tester.enterText(find.byType(TextField), 'New_York');
    await tester.pumpAndSettle();
    expect(find.text('America/New_York'), findsOneWidget);

    await tester.tap(find.text('America/New_York'));
    await tester.pumpAndSettle();

    final container =
        ProviderScope.containerOf(tester.element(find.byType(TimezoneSettingsScreen)));
    final state = container.read(timezoneSettingsNotifierProvider);
    expect(state.isAutomatic, isFalse);
    expect(state.overrideZoneId, 'America/New_York');
  });
}
