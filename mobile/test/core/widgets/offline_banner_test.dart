// Proves OfflineBanner (M3 slice 1's reusable "showing cached data" banner):
// hidden while online/offline-without-cache, visible with a relative-time
// hint while offlineWithCache.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/core/widgets/offline_banner.dart';

void main() {
  Future<void> pumpBanner(WidgetTester tester, ConnectivityStatus status) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [connectivityStatusProvider.overrideWith(() => _FixedConnectivityNotifier(status))],
        child: const MaterialApp(home: Scaffold(body: OfflineBanner())),
      ),
    );
  }

  testWidgets('renders nothing while online', (tester) async {
    await pumpBanner(tester, const ConnectivityStatus(state: ConnectivityState.online));

    expect(find.byType(OfflineBanner), findsOneWidget);
    expect(find.text('Sin conexión', findRichText: true), findsNothing);
    expect(find.byIcon(Icons.cloud_off), findsNothing);
  });

  testWidgets('renders nothing while offline without a cache fallback', (tester) async {
    await pumpBanner(tester, const ConnectivityStatus(state: ConnectivityState.offline));

    expect(find.byIcon(Icons.cloud_off), findsNothing);
  });

  testWidgets('shows the cached-data banner with a relative time hint while offlineWithCache', (tester) async {
    final fetchedAt = DateTime.now().subtract(const Duration(minutes: 5));
    await pumpBanner(
      tester,
      ConnectivityStatus(state: ConnectivityState.offlineWithCache, lastSyncAt: fetchedAt),
    );

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.textContaining('Sin conexión'), findsOneWidget);
    expect(find.textContaining('hace 5 min'), findsOneWidget);
  });
}

class _FixedConnectivityNotifier extends ConnectivityNotifier {
  _FixedConnectivityNotifier(this._fixed);

  final ConnectivityStatus _fixed;

  @override
  ConnectivityStatus build() => _fixed;
}
