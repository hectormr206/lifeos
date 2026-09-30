// Home is Axi's greeting first, with quiet grouped navigation beneath (or beside it).
// Fixed clock, fake on-device model and no connection keep each capture stable.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/features/home/presentation/home_screen.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../features/local_model/support/fake_local_llm_engine.dart';
import '../support/fake_token_store.dart';
import 'support/golden_harness.dart';

class _EveningClock implements Clock {
  @override
  DateTime now() => DateTime(2026, 7, 22, 21, 30);
}

Widget _home(ThemeData theme) => ProviderScope(
      overrides: [
        clockProvider.overrideWithValue(_EveningClock()),
        tokenStoreProvider.overrideWithValue(FakeTokenStore()),
        localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: true)),
        localModelPreferencesProvider.overrideWithValue(FakeLocalModelPreferences()),
      ],
      child: MaterialApp(
        theme: theme,
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child ?? const SizedBox.shrink(),
        ),
        home: const HomeScreen(),
      ),
    );

void main() {
  for (final (name, theme) in [
    ('home_dark.png', goldenDarkTheme()),
    ('home_light.png', goldenTheme()),
    ('home_wide_light.png', goldenTheme()),
  ]) {
    testWidgets('golden: $name', (tester) async {
      if (name == 'home_wide_light.png') {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
      } else {
        useGoldenSurface(tester);
      }
      await tester.pumpWidget(_home(theme));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Chatear con Axi (sin conexión)'), findsOneWidget);
      await expectLater(find.byType(HomeScreen), matchesGoldenFile('images/$name'));
    });
  }
}
