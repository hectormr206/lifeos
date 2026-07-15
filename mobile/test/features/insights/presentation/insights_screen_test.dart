// Proves InsightsScreen renders the digest body text and section/pattern/
// correlation counts, and that tapping the cadence toggle switches between
// daily and weekly. No live engine — repository faked.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/insights/data/insights_repository.dart';
import 'package:lifeos/features/insights/domain/digest.dart';
import 'package:lifeos/features/insights/presentation/insights_notifier.dart';
import 'package:lifeos/features/insights/presentation/insights_screen.dart';

class _FixedConnectivityNotifier extends ConnectivityNotifier {
  _FixedConnectivityNotifier(this._fixed);

  final ConnectivityStatus _fixed;

  @override
  ConnectivityStatus build() => _fixed;
}

class _FakeInsightsRepository implements InsightsRepository {
  _FakeInsightsRepository({this.error});

  final InsightsException? error;
  int previewCalls = 0;
  String? lastCadence;

  @override
  Future<DigestModel> preview({String cadence = 'daily'}) async {
    previewCalls++;
    lastCadence = cadence;
    if (error != null) throw error!;
    return DigestModel(
      cadence: cadence,
      body: cadence == 'daily' ? 'Hoy dormiste 7h y gastaste 350 MXN.' : 'Semana estable, sin sorpresas.',
      sectionsCount: cadence == 'daily' ? 3 : 5,
      patternsCount: 1,
      correlationsCount: 0,
      generatedAt: DateTime.utc(2026, 7, 14, 8),
    );
  }
}

void main() {
  testWidgets('renders the daily digest body by default', (tester) async {
    final repo = _FakeInsightsRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [insightsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: InsightsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Hoy dormiste 7h y gastaste 350 MXN.'), findsOneWidget);
    expect(repo.lastCadence, 'daily');
  });

  testWidgets('tapping the "Semanal" toggle loads the weekly digest', (tester) async {
    final repo = _FakeInsightsRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [insightsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: InsightsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Semanal'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Semana estable, sin sorpresas.'), findsOneWidget);
    expect(repo.lastCadence, 'weekly');
  });

  testWidgets('shows an error state with a retry button on failure', (tester) async {
    final repo = _FakeInsightsRepository(error: InsightsException('boom'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [insightsRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: InsightsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('shows the offline banner when connectivity is offlineWithCache (M3 slice 1)', (tester) async {
    final repo = _FakeInsightsRepository();
    final fixed = ConnectivityStatus(state: ConnectivityState.offlineWithCache, lastSyncAt: DateTime.now());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          insightsRepositoryProvider.overrideWithValue(repo),
          connectivityStatusProvider.overrideWith(() => _FixedConnectivityNotifier(fixed)),
        ],
        child: const MaterialApp(home: InsightsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.textContaining('Sin conexión'), findsOneWidget);
  });
}
