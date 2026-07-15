// Proves DigestScreen ("Resumen de hoy") renders today's counts as chips,
// the generated summary text when present, and an empty/no-summary state.
// No live engine — repository faked.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/digest/data/digest_repository.dart';
import 'package:lifeos/features/digest/domain/today_digest.dart';
import 'package:lifeos/features/digest/presentation/digest_notifier.dart';
import 'package:lifeos/features/digest/presentation/digest_screen.dart';

class _FixedConnectivityNotifier extends ConnectivityNotifier {
  _FixedConnectivityNotifier(this._fixed);

  final ConnectivityStatus _fixed;

  @override
  ConnectivityStatus build() => _fixed;
}

class _FakeDigestRepository implements DigestRepository {
  _FakeDigestRepository({this.digest, this.error});

  final TodayDigest? digest;
  final DigestException? error;
  int todayCalls = 0;

  @override
  Future<TodayDigest> today() async {
    todayCalls++;
    if (error != null) throw error!;
    return digest ??
        const TodayDigest(
          date: '2026-07-14',
          conversationsCount: 0,
          meetingsCount: 0,
          factsAddedCount: 0,
          eventsCriticalCount: 0,
          eventsErrorCount: 0,
        );
  }
}

Future<void> _pumpDigest(WidgetTester tester, _FakeDigestRepository repo) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [digestRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: DigestScreen()),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('renders the counts and the generated summary', (tester) async {
    const digest = TodayDigest(
      date: '2026-07-14',
      conversationsCount: 4,
      meetingsCount: 1,
      factsAddedCount: 2,
      eventsCriticalCount: 0,
      eventsErrorCount: 1,
      generatedSummary: 'Buen día: dormiste bien y tuviste una reunión productiva.',
    );
    final repo = _FakeDigestRepository(digest: digest);
    await _pumpDigest(tester, repo);

    expect(find.text('Buen día: dormiste bien y tuviste una reunión productiva.'), findsOneWidget);
    expect(find.textContaining('4'), findsWidgets);
  });

  testWidgets('shows a placeholder when there is no generated summary', (tester) async {
    const digest = TodayDigest(
      date: '2026-07-14',
      conversationsCount: 0,
      meetingsCount: 0,
      factsAddedCount: 0,
      eventsCriticalCount: 0,
      eventsErrorCount: 0,
    );
    final repo = _FakeDigestRepository(digest: digest);
    await _pumpDigest(tester, repo);

    expect(find.text('Aún no hay un resumen narrado disponible.'), findsOneWidget);
  });

  testWidgets('renders top facts when present', (tester) async {
    const digest = TodayDigest(
      date: '2026-07-14',
      conversationsCount: 1,
      meetingsCount: 0,
      factsAddedCount: 1,
      eventsCriticalCount: 0,
      eventsErrorCount: 0,
      topFacts: [DigestFact(id: 1, label: 'Dormiste 7h', domain: 'health')],
    );
    final repo = _FakeDigestRepository(digest: digest);
    await _pumpDigest(tester, repo);

    expect(find.text('• Dormiste 7h'), findsOneWidget);
  });

  testWidgets('shows an error state with a retry button on failure', (tester) async {
    final repo = _FakeDigestRepository(error: DigestException('boom'));
    await _pumpDigest(tester, repo);

    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('shows the offline banner when connectivity is offlineWithCache', (tester) async {
    final repo = _FakeDigestRepository();
    final fixed = ConnectivityStatus(state: ConnectivityState.offlineWithCache, lastSyncAt: DateTime.now());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          digestRepositoryProvider.overrideWithValue(repo),
          connectivityStatusProvider.overrideWith(() => _FixedConnectivityNotifier(fixed)),
        ],
        child: const MaterialApp(home: DigestScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.textContaining('Sin conexión'), findsOneWidget);
  });
}
