// Smoke test for the root of the app (design D1 foundation).
//
// M1 slice 1: HomeScreen no longer shows the placeholder "is alive" text —
// it now shows the connection status (spec mobile-app-shell). Overrides
// tokenStoreProvider so ConnectionNotifier's startup bootstrap never touches
// the real flutter_secure_storage platform channel (unavailable in this
// test environment) and stays deterministically Unpaired.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';

import 'support/fake_token_store.dart';

void main() {
  testWidgets('LifeOSApp boots to the home screen (app-shell: no connect CTA)', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(FakeTokenStore())],
        child: const LifeOSApp(),
      ),
    );
    await tester.pump();

    expect(find.text('LifeOS'), findsWidgets);
    // App-shell slice: the "Conectar con tu motor" CTA was removed from home.
    expect(find.text('Conectar con tu motor'), findsNothing);
    expect(find.text('Aún no está conectado a ningún motor.'), findsOneWidget);
  });
}
