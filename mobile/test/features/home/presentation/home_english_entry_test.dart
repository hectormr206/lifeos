// The "Inglés" home row opens the English home, on an unpaired device.
//
// Learning English is a daily activity, so its door is on home, not in
// Settings. And like everything on home it works on the device's own data:
// the word bank ships inside the app, and results go to the local graph.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../../../support/fake_token_store.dart';

void main() {
  testWidgets('unpaired: the "Inglés" row opens the English home',
      (tester) async {
    final container = ProviderContainer(overrides: [
      localeProvider.overrideWithValue(const Locale('es')),
      tokenStoreProvider.overrideWithValue(FakeTokenStore()),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const LifeOSApp()),
    );
    await tester.pump();

    expect(find.text('Aprender'), findsOneWidget);
    // Invoked directly, not tapped: see home_brain_entry_test.dart for why a
    // tap inside the scrolling home menu can land on the AppBar instead.
    tester
        .widget<OutlinedButton>(find.ancestor(
          of: find.text('Inglés'),
          matching: find.byType(OutlinedButton),
        ))
        .onPressed!();
    // Bounded pumps: the placement watches the local graph store, which never
    // resolves in tests, so pumpAndSettle would wait forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Inglés'),
      ),
      findsOneWidget,
    );
    expect(find.text('Conectar con tu motor'), findsNothing);
  });
}
