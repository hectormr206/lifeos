// Smoke test for the root of the app (design D1 foundation).
//
// This replaces the default `flutter create` counter widget test: the
// counter demo is gone, replaced by a minimal "the app is alive" home
// screen wired through Riverpod's [ProviderScope].
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lifeos/app.dart';

void main() {
  testWidgets('LifeOSApp boots to the home screen with a ProviderScope root', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: LifeOSApp()));
    await tester.pump();

    expect(find.text('LifeOS'), findsWidgets);
    expect(find.textContaining('alive'), findsOneWidget);
  });
}
