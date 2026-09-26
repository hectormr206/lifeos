// "Hoy": the daily plan where the learner sees it first.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/english_phase_store.dart';
import 'package:lifeos/features/english/data/english_placement_repository.dart';
import 'package:lifeos/features/english/domain/daily_plan.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/english/presentation/english_today_card.dart';
import 'package:lifeos/l10n/app_localizations.dart';

class _Phases implements EnglishPhaseStore {
  _Phases([this.phase]);
  StudyPhase? phase;
  @override
  Future<StudyPhase?> read() async => phase;
  @override
  Future<void> write(StudyPhase phase) async => this.phase = phase;
}

StudyActivity _did(int daysAgo, int minutes, [ActivityKind kind = ActivityKind.review]) =>
    StudyActivity(
      kind: kind,
      at: DateTime.now().subtract(Duration(days: daysAgo)),
      minutes: minutes,
    );

Widget _app({
  List<StudyActivity> activities = const [],
  _Phases? phases,
  PlacementRecord? placement,
}) =>
    ProviderScope(
      overrides: [
        studyActivitiesProvider.overrideWith((ref) async => activities),
        englishPhaseStoreProvider.overrideWith((ref) async => phases ?? _Phases()),
        latestPlacementProvider.overrideWith((ref) async => placement),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: EnglishTodayCard())),
      ),
    );

void main() {
  testWidgets('the first day: fifteen minutes, review and one reading',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.textContaining('15 min'), findsWidgets);
    expect(find.textContaining('Repasar palabras'), findsOneWidget);
    expect(find.textContaining('Leer y escuchar'), findsOneWidget);
    expect(find.textContaining('Llevas 0 de 15'), findsOneWidget);
  });

  testWidgets('five minutes today and the day is done', (tester) async {
    await tester.pumpWidget(_app(activities: [_did(0, 6)]));
    await tester.pumpAndSettle();

    expect(find.textContaining('Día cumplido'), findsOneWidget);
  });

  testWidgets('after a missed day, only the floor, without guilt',
      (tester) async {
    await tester.pumpWidget(_app(activities: [_did(2, 15)]));
    await tester.pumpAndSettle();

    expect(find.textContaining('basta con 5 minutos'), findsOneWidget);
    expect(find.textContaining('Leer y escuchar'), findsNothing);
  });

  testWidgets('the week shows days practised, not a streak', (tester) async {
    await tester.pumpWidget(
        _app(activities: [_did(0, 6), _did(1, 10), _did(3, 15)]));
    await tester.pumpAndSettle();

    expect(find.textContaining('3 de 7'), findsOneWidget);
  });

  testWidgets('a sustained start is offered more, and the choice is kept',
      (tester) async {
    final phases = _Phases();
    await tester.pumpWidget(_app(
      activities: [for (var d = 1; d <= 14; d++) _did(d, 15)],
      phases: phases,
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('¿Subimos a 30 minutos'), findsOneWidget);
    await tester.tap(find.text('Sí, subir'));
    await tester.pumpAndSettle();

    expect(phases.phase, StudyPhase.build);
    expect(find.textContaining('Conversar'), findsOneWidget);
  });

  testWidgets('the pace can always be lowered', (tester) async {
    final phases = _Phases(StudyPhase.build);
    await tester.pumpWidget(_app(phases: phases));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bajar el ritmo'));
    await tester.pumpAndSettle();

    expect(phases.phase, StudyPhase.start);
  });

  testWidgets('a month after the last placement it suggests measuring again',
      (tester) async {
    await tester.pumpWidget(_app(
      placement: PlacementRecord(
        takenAt: DateTime.now().subtract(const Duration(days: 40)),
        result: const VocabPlacementResult(
          knownByBand: [1],
          falseAlarmRate: 0,
          estimatedWords: 1000,
          xlexScore: 1000,
          cefr: CefrLevel.a1,
          reliable: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Pasó un mes'), findsOneWidget);
  });

  testWidgets('a step done today is marked', (tester) async {
    await tester.pumpWidget(_app(activities: [_did(0, 5, ActivityKind.review)]));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}
