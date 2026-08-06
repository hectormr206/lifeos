// Proves the two-tab labels are PLATFORM-HONEST and localized.
//
// The old labels were "En este teléfono" / "Desde tu laptop". On the installed
// Linux desktop build (/opt/lifeos) the second one is absurd — you ARE on the
// laptop. The fix is device-neutral wording rather than a platform conditional,
// because both sentences are true on every platform once they stop naming the
// hardware:
//
//   tab 1 = local CRUD on the on-device encrypted graph  → "En este dispositivo"
//   tab 2 = the pairing-gated view of the Axi ENGINE     → "Desde el motor Axi"
//
// Tab 2 names the engine, not the machine it happens to run on. "Motor" is
// already the app's word for it (Settings → "Configuración del motor").
//
// Asserted for BOTH platforms: no conditional means Android renders exactly the
// same labels, so the Pixel build cannot drift.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

void main() {
  Widget wrap(Widget child, {required String operatingSystem, required String locale}) =>
      ProviderScope(
        overrides: [
          hostOperatingSystemProvider.overrideWithValue(operatingSystem),
        ],
        child: MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: child,
        ),
      );

  group('the localized tab strings', () {
    testWidgets('Spanish names the device and the engine, never the hardware',
        (tester) async {
      late AppLocalizations l10n;
      await tester.pumpWidget(wrap(
        Builder(builder: (context) {
          l10n = AppLocalizations.of(context);
          return const SizedBox.shrink();
        }),
        operatingSystem: 'linux',
        locale: 'es',
      ));

      expect(l10n.domainTabLocal, 'En este dispositivo');
      expect(l10n.domainTabEngine, 'Desde el motor Axi');
      // The whole point: neither string names a phone or a laptop.
      expect(l10n.domainTabLocal.toLowerCase(), isNot(contains('teléfono')));
      expect(l10n.domainTabEngine.toLowerCase(), isNot(contains('laptop')));
    });

    testWidgets('English mirrors it', (tester) async {
      late AppLocalizations l10n;
      await tester.pumpWidget(wrap(
        Builder(builder: (context) {
          l10n = AppLocalizations.of(context);
          return const SizedBox.shrink();
        }),
        operatingSystem: 'linux',
        locale: 'en',
      ));

      expect(l10n.domainTabLocal, 'On this device');
      expect(l10n.domainTabEngine, 'From the Axi engine');
      expect(l10n.domainTabLocal.toLowerCase(), isNot(contains('phone')));
      expect(l10n.domainTabEngine.toLowerCase(), isNot(contains('laptop')));
    });

    testWidgets('the labels do not depend on the host OS', (tester) async {
      // Deliberate: device-neutral wording is preferred over a platform
      // conditional wherever the sentence is true either way, so Android and
      // Linux must resolve to the SAME strings.
      final seen = <String, List<String>>{};
      for (final os in ['android', 'linux']) {
        late AppLocalizations l10n;
        await tester.pumpWidget(wrap(
          Builder(builder: (context) {
            l10n = AppLocalizations.of(context);
            return const SizedBox.shrink();
          }),
          operatingSystem: os,
          locale: 'es',
        ));
        seen[os] = [l10n.domainTabLocal, l10n.domainTabEngine];
      }
      expect(seen['android'], seen['linux']);
    });
  });
}
