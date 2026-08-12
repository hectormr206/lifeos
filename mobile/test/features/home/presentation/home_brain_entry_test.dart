// Proves the LABELLED "Cerebro" home entry opens the ON-DEVICE 3D brain, and
// that it does so with no engine pairing.
//
// WHY THIS EXISTS. The app grew two unrelated features both called "Cerebro":
//
//   * `/graph` — GraphBrowserScreen, a search box over the engine's HTTP
//     `/api/v1/graph/*`. Added 2026-07-14 (16dad370), correctly pairing-gated
//     because it genuinely cannot work without the engine.
//   * `/brain3d` — Brain3dScreen, a native CustomPainter force-layout of the
//     ON-DEVICE encrypted graph (LocalGraphStore). Added 9 days later
//     (431ac2d1), needs no network and no pairing.
//
// The home row labelled "Cerebro" pointed at the REMOTE one, and no commit ever
// revisited it. So the working, local, autonomous feature was reachable only by
// tapping an unlabelled ~48x26dp region on the mascot's forehead, while the
// labelled row bounced an unpaired user to the connection screen.
//
// LifeOS is meant to be autonomous: pairing is a SYNC relationship, not a
// licence that unlocks features. The label therefore belongs to the surface
// that works on the device's own data. The remote graph browser keeps its own
// clearly-named row and its gate.
//
// The mascot hitbox stays — it is a deliberate, documented port of the laptop
// dashboard's clickable-organ SVG — it is simply no longer the ONLY way in.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/app.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/features/connection/presentation/connection_screen.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../../../support/fake_token_store.dart';

Future<void> _pumpHome(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const LifeOSApp()),
  );
  await tester.pump();
}

/// Fires the home row carrying [label].
///
/// The callback is invoked directly rather than tapped: the home menu lives in
/// a scroll view, and `ensureVisible` parks a row just far enough that the tap
/// coordinate lands on the AppBar instead — a silent miss that makes the test
/// pass or fail on pixel geometry rather than on the wiring. What is under test
/// here is WHICH DESTINATION each labelled row goes to, so drive it at that
/// seam. That the rows are tappable at all is already covered by the existing
/// home screen tests.
Future<void> _pressRow(WidgetTester tester, String label) async {
  final button = tester.widget<OutlinedButton>(
    find.ancestor(of: find.text(label), matching: find.byType(OutlinedButton)),
  );
  button.onPressed!();
  // Bounded pumps: a destination may open a (never-resolving in tests) local
  // graph store, so pumpAndSettle would hang on its loading spinner.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('unpaired: the labelled "Cerebro" row opens the on-device 3D brain',
      (tester) async {
    final container = ProviderContainer(overrides: [
      // Pin Spanish so this asserts the screen's copy, not the CI host's locale.
      localeProvider.overrideWithValue(const Locale('es')),
      tokenStoreProvider.overrideWithValue(FakeTokenStore()),
    ]);
    addTearDown(container.dispose);

    await _pumpHome(tester, container);

    expect(find.text('Cerebro'), findsOneWidget,
        reason: 'the local brain must carry the plain label');

    await _pressRow(tester, 'Cerebro');

    // The whole point: an UNPAIRED device lands on the local brain, and is NOT
    // bounced to the pairing screen. Scoped to the AppBar because the home
    // route underneath is still mounted during these bounded pumps.
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Cerebro 3D')),
      findsOneWidget,
    );
    expect(find.text('Conectar con tu motor'), findsNothing);
  });

  testWidgets('unpaired: the engine graph browser keeps its own labelled row, still gated',
      (tester) async {
    final container = ProviderContainer(overrides: [
      localeProvider.overrideWithValue(const Locale('es')),
      tokenStoreProvider.overrideWithValue(FakeTokenStore()),
    ]);
    addTearDown(container.dispose);

    await _pumpHome(tester, container);

    // The remote twin is still reachable BY NAME — removing it would hide a
    // real capability from a paired user — but it says whose brain it is.
    expect(find.text('Cerebro del motor'), findsOneWidget);

    await _pressRow(tester, 'Cerebro del motor');

    // It genuinely needs the engine (GET /api/v1/graph/search), so unpaired it
    // must still route to pairing rather than open and then error. The engine
    // browser's own AppBar ("Cerebro") must therefore NOT be on screen.
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('Cerebro 3D')),
      findsNothing,
    );
    expect(find.byType(ConnectionScreen), findsOneWidget);
  });
}
