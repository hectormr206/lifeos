// Proves the list -> detail flow: MeetingsScreen renders one row per
// meeting, tapping one pushes MeetingDetailScreen at /meetings/:id
// (transcript/participants/summary), and the empty-list state. Also covers
// the offline banner (M3 slice 1). No live engine — repository faked. Real
// GoRouter (mirrors graph_browser_screen_test.dart's push-navigation
// pattern).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/connectivity/connectivity_status.dart';
import 'package:lifeos/features/meetings/data/meetings_repository.dart';
import 'package:lifeos/features/meetings/domain/meeting.dart';
import 'package:lifeos/features/meetings/domain/meeting_detail.dart';
import 'package:lifeos/features/meetings/presentation/meeting_detail_screen.dart';
import 'package:lifeos/features/meetings/presentation/meetings_notifier.dart';
import 'package:lifeos/features/meetings/presentation/meetings_screen.dart';

class _FixedConnectivityNotifier extends ConnectivityNotifier {
  _FixedConnectivityNotifier(this._fixed);

  final ConnectivityStatus _fixed;

  @override
  ConnectivityStatus build() => _fixed;
}

class _FakeMeetingsRepository implements MeetingsRepository {
  _FakeMeetingsRepository({this.meetings = const [], this.details = const {}});

  final List<MeetingModel> meetings;
  final Map<int, MeetingDetail> details;

  @override
  Future<List<MeetingModel>> list() async => meetings;

  @override
  Future<MeetingDetail> detail(int id) async {
    final detail = details[id];
    if (detail == null) throw MeetingsException('reunión no encontrada');
    return detail;
  }
}

GoRouter _router() => GoRouter(
      routes: [
        GoRoute(path: '/meetings', builder: (context, state) => const MeetingsScreen()),
        GoRoute(
          path: '/meetings/:id',
          builder: (context, state) => MeetingDetailScreen(meetingId: int.parse(state.pathParameters['id']!)),
        ),
      ],
      initialLocation: '/meetings',
    );

void main() {
  final teamSync = MeetingModel(
    id: 12,
    start: '2026-07-10 09:00',
    startTs: DateTime.utc(2026, 7, 10, 9),
    end: '2026-07-10 09:45',
    durationS: 2700,
    status: 'done',
    source: 'auto',
    hasTranscript: true,
    hasSummary: true,
  );
  final teamSyncDetail = MeetingDetail(
    id: 12,
    start: '2026-07-10 09:00',
    end: '2026-07-10 09:45',
    durationS: 2700,
    status: 'done',
    transcript: 'Hola a todos. Empecemos.',
    summary: 'Se discutió el roadmap del trimestre.',
    segments: const [
      MeetingSegment(channel: 'system', startMs: 0, endMs: 3000, text: 'Hola a todos.', speakerLabel: 'Héctor'),
    ],
    speakers: const [
      MeetingSpeaker(id: 1, name: 'Héctor', segmentCount: 1, firstMs: 0),
    ],
  );

  testWidgets('shows an empty state when there are no meetings', (tester) async {
    final repo = _FakeMeetingsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [meetingsRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp.router(routerConfig: _router()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Aún no hay reuniones.'), findsOneWidget);
  });

  testWidgets('list -> tap -> detail flow (transcript/participantes/resumen)', (tester) async {
    final repo = _FakeMeetingsRepository(meetings: [teamSync], details: {12: teamSyncDetail});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [meetingsRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp.router(routerConfig: _router()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('2026-07-10 09:00'), findsOneWidget);

    await tester.tap(find.text('2026-07-10 09:00'));
    await tester.pumpAndSettle();

    expect(find.text('Se discutió el roadmap del trimestre.'), findsOneWidget);
    expect(find.text('Héctor'), findsWidgets);
    expect(find.text('Hola a todos.'), findsOneWidget);
  });

  testWidgets('shows the offline banner when connectivity is offlineWithCache (M3 slice 1)', (tester) async {
    final repo = _FakeMeetingsRepository();
    final fixed = ConnectivityStatus(state: ConnectivityState.offlineWithCache, lastSyncAt: DateTime.now());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meetingsRepositoryProvider.overrideWithValue(repo),
          connectivityStatusProvider.overrideWith(() => _FixedConnectivityNotifier(fixed)),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.textContaining('Sin conexión'), findsOneWidget);
  });
}
