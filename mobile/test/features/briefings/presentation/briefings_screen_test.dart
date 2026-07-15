// Proves BriefingsScreen (Boletines — agentic briefings) renders one card
// per briefing, an empty state, and that tapping a briefing with a fired
// result expands it to show the result detail (title/summary/items) — the
// detail is rendered from the SAME list item since the engine has no
// per-id detail route (see BriefingsRepository's scope note). No live
// engine — repository faked.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/briefings/data/briefings_repository.dart';
import 'package:lifeos/features/briefings/domain/briefing.dart';
import 'package:lifeos/features/briefings/presentation/briefings_notifier.dart';
import 'package:lifeos/features/briefings/presentation/briefings_screen.dart';

class _FixedConnectivityNotifier extends ConnectivityNotifier {
  _FixedConnectivityNotifier(this._fixed);

  final ConnectivityStatus _fixed;

  @override
  ConnectivityStatus build() => _fixed;
}

class _FakeBriefingsRepository implements BriefingsRepository {
  _FakeBriefingsRepository({this.briefings = const [], this.error});

  final List<BriefingModel> briefings;
  final BriefingsException? error;
  int listCalls = 0;

  @override
  Future<List<BriefingModel>> list() async {
    listCalls++;
    if (error != null) throw error!;
    return briefings;
  }
}

Future<void> _pumpBriefings(WidgetTester tester, _FakeBriefingsRepository repo) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [briefingsRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(home: BriefingsScreen()),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('renders one card per briefing with its message', (tester) async {
    final briefings = [
      BriefingModel(id: '1', message: 'Resumen semanal de finanzas', whenTs: DateTime(2026, 7, 20)),
      BriefingModel(id: '2', message: 'Chequeo diario de salud', whenTs: DateTime(2026, 7, 15)),
    ];
    final repo = _FakeBriefingsRepository(briefings: briefings);
    await _pumpBriefings(tester, repo);

    expect(find.text('Resumen semanal de finanzas'), findsOneWidget);
    expect(find.text('Chequeo diario de salud'), findsOneWidget);
  });

  testWidgets('shows an empty state when there are no briefings', (tester) async {
    final repo = _FakeBriefingsRepository();
    await _pumpBriefings(tester, repo);

    expect(find.text('Aún no tienes boletines.'), findsOneWidget);
  });

  testWidgets('tapping a briefing with a fired result expands it to show the summary', (tester) async {
    final briefing = BriefingModel(
      id: '1',
      message: 'Resumen semanal de finanzas',
      whenTs: DateTime(2026, 7, 20),
      result: const BriefingResult(
        title: 'Finanzas de la semana',
        summary: 'Gastaste 1200 MXN, 10% menos que la semana pasada.',
        items: ['Comida: 500', 'Transporte: 300'],
      ),
    );
    final repo = _FakeBriefingsRepository(briefings: [briefing]);
    await _pumpBriefings(tester, repo);

    expect(find.text('Gastaste 1200 MXN, 10% menos que la semana pasada.'), findsNothing);

    await tester.tap(find.text('Resumen semanal de finanzas'));
    await tester.pumpAndSettle();

    expect(find.text('Gastaste 1200 MXN, 10% menos que la semana pasada.'), findsOneWidget);
    expect(find.text('• Comida: 500'), findsOneWidget);
  });

  testWidgets('a briefing with no result yet shows a pending detail message on expand', (tester) async {
    final briefing = BriefingModel(id: '1', message: 'Chequeo diario de salud', whenTs: DateTime(2026, 7, 15));
    final repo = _FakeBriefingsRepository(briefings: [briefing]);
    await _pumpBriefings(tester, repo);

    await tester.tap(find.text('Chequeo diario de salud'));
    await tester.pumpAndSettle();

    expect(find.text('Aún no se ha ejecutado.'), findsOneWidget);
  });

  testWidgets('shows an error state with a retry button on failure', (tester) async {
    final repo = _FakeBriefingsRepository(error: BriefingsException('boom'));
    await _pumpBriefings(tester, repo);

    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Reintentar'), findsOneWidget);
  });

  testWidgets('shows the offline banner when connectivity is offlineWithCache', (tester) async {
    final repo = _FakeBriefingsRepository();
    final fixed = ConnectivityStatus(state: ConnectivityState.offlineWithCache, lastSyncAt: DateTime.now());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          briefingsRepositoryProvider.overrideWithValue(repo),
          connectivityStatusProvider.overrideWith(() => _FixedConnectivityNotifier(fixed)),
        ],
        child: const MaterialApp(home: BriefingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.textContaining('Sin conexión'), findsOneWidget);
  });
}
