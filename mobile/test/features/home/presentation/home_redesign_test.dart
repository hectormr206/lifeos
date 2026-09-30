import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/features/home/presentation/home_providers.dart';
import 'package:lifeos/features/home/presentation/home_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/theme/lifeos_palette.dart';
import 'package:lifeos/theme/lifeos_theme.dart';

import '../../../support/fake_token_store.dart';

class _FixedClock implements Clock {
  const _FixedClock(this.hour, this.minute);
  final int hour;
  final int minute;
  @override
  DateTime now() => DateTime(2026, 7, 22, hour, minute);
}

Widget _app({required Clock clock, bool paired = false, bool reachable = true, Locale locale = const Locale('es')}) =>
    ProviderScope(
      overrides: [
        clockProvider.overrideWithValue(clock),
        tokenStoreProvider.overrideWithValue(FakeTokenStore(paired
            ? const StoredConnection(engineUrl: 'https://engine', token: 'tok', deviceId: 'one')
            : null)),
        engineReachableProvider.overrideWith((ref) async => reachable),
      ],
      child: MaterialApp(
        theme: lifeosLightTheme,
        locale: locale,
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
  for (final (hour, minute, greeting) in [
    (4, 59, 'Buenas noches'),
    (5, 0, 'Buenos días'),
    (11, 59, 'Buenos días'),
    (12, 0, 'Buenas tardes'),
    (19, 59, 'Buenas tardes'),
    (20, 0, 'Buenas noches'),
  ]) {
    testWidgets('Spanish greeting at $hour:$minute is $greeting', (tester) async {
      await tester.pumpWidget(_app(clock: _FixedClock(hour, minute)));
      await tester.pump();
      expect(find.text(greeting), findsOneWidget);
      expect(find.text('¿Qué quieres contarme?'), findsOneWidget);
    });
  }

  testWidgets('English greeting uses localized copy', (tester) async {
    await tester.pumpWidget(_app(clock: const _FixedClock(12, 0), locale: const Locale('en')));
    await tester.pump();
    expect(find.text('Good afternoon'), findsOneWidget);
    expect(find.text("What's on your mind?"), findsOneWidget);
  });

  testWidgets('wide home holds greeting and sections in side-by-side panes', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(_app(clock: const _FixedClock(21, 30)));
    await tester.pump();
    final greeting = tester.getRect(find.text('Buenas noches'));
    final records = tester.getRect(find.text('Tus registros'));
    expect(records.left, greaterThan(greeting.right));
    expect(records.top, lessThan(greeting.bottom));
    expect(records.bottom, greaterThan(greeting.top));
  });

  for (final reachable in [true, false]) {
    testWidgets('status dot uses semantic ${reachable ? 'success' : 'error'} color', (tester) async {
      await tester.pumpWidget(_app(clock: const _FixedClock(21, 30), paired: true, reachable: reachable));
      await tester.pump();
      await tester.pump();
      final dot = tester.widget<Container>(find.byKey(const Key('home-engine-status-dot')));
      final expected = reachable
          ? LifeOSPalette.of(tester.element(find.byType(HomeScreen))).success
          : Theme.of(tester.element(find.byType(HomeScreen))).colorScheme.error;
      expect((dot.decoration! as BoxDecoration).color, expected);
    });
  }
}
