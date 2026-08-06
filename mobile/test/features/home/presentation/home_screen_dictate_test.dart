// Proves the "Dictar" quick action is on the home screen, on BOTH platforms,
// and that it opens the dictation surface.
//
// The user asked for the quick action he already has on his laptop's Axi
// dashboard, on Android AND Linux — so unlike the Android-only Settings rows,
// this one is deliberately NOT platform-conditional between those two. It is
// absent only where the capability genuinely cannot exist (see
// `supportsDictation` in test/core/platform/app_platform_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/auth/token_store.dart';
import 'package:lifeos/core/platform/platform_providers.dart';
import 'package:lifeos/features/home/presentation/home_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

import '../../../support/fake_token_store.dart';

Widget _app({required String operatingSystem}) => ProviderScope(
      overrides: [
        hostOperatingSystemProvider.overrideWithValue(operatingSystem),
        tokenStoreProvider.overrideWithValue(
          FakeTokenStore(const StoredConnection(
            engineUrl: 'https://10.66.66.2:8081',
            token: 'tok',
            deviceId: 'dev-1',
          )),
        ),
      ],
      child: MaterialApp.router(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(path: '/', builder: (c, s) => const HomeScreen()),
            GoRoute(path: '/dictate', builder: (c, s) => const Scaffold(body: Text('DICTATE'))),
          ],
        ),
      ),
    );

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.physicalSize = const Size(1000, 3200);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  for (final os in ['android', 'linux']) {
    testWidgets('$os shows the Dictar quick action', (tester) async {
      await tester.pumpWidget(_app(operatingSystem: os));
      await tester.pumpAndSettle();

      expect(find.text('Dictar'), findsOneWidget);
    });

    testWidgets('$os opens the dictation screen when tapped', (tester) async {
      await tester.pumpWidget(_app(operatingSystem: os));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Dictar'));
      await tester.pumpAndSettle();

      expect(find.text('DICTATE'), findsOneWidget);
    });
  }
}
