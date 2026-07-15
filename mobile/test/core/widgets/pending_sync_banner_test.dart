// Proves PendingSyncBanner (M3 slice 2's "N pendientes por sincronizar"
// indicator): hidden while the outbox is empty, visible with the pending
// count while entries are queued. Mirrors offline_banner_test.dart's
// pattern.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/outbox/outbox.dart';
import 'package:lifeos/core/widgets/pending_sync_banner.dart';

void main() {
  Future<void> pumpBanner(WidgetTester tester, int count) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pendingSyncCountProvider.overrideWith(() => _FixedPendingSyncCountNotifier(count))],
        child: const MaterialApp(home: Scaffold(body: PendingSyncBanner())),
      ),
    );
  }

  testWidgets('renders nothing while there are no pending entries', (tester) async {
    await pumpBanner(tester, 0);

    expect(find.byType(PendingSyncBanner), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsNothing);
  });

  testWidgets('shows the singular count', (tester) async {
    await pumpBanner(tester, 1);

    expect(find.byIcon(Icons.sync), findsOneWidget);
    expect(find.textContaining('1 pendiente'), findsOneWidget);
  });

  testWidgets('shows the plural count', (tester) async {
    await pumpBanner(tester, 3);

    expect(find.byIcon(Icons.sync), findsOneWidget);
    expect(find.textContaining('3 pendientes'), findsOneWidget);
  });
}

class _FixedPendingSyncCountNotifier extends PendingSyncCountNotifier {
  _FixedPendingSyncCountNotifier(this._fixed);

  final int _fixed;

  @override
  int build() => _fixed;
}
