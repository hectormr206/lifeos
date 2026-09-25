// The English home: where you stand, and what you want English for.
//
// The level comes from the placement; the goal is one choice that changes
// what you read and practise. Neither is ever filled in with a default: no
// placement means "you don't know yet", not "A1".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/features/english/data/english_goal_store.dart';
import 'package:lifeos/features/english/data/english_placement_repository.dart';
import 'package:lifeos/features/english/domain/english_goal.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';
import 'package:lifeos/features/english/presentation/english_hub_screen.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

class _FakeGoals implements EnglishGoalStore {
  _FakeGoals([this.goal]);

  EnglishGoal? goal;
  final List<EnglishGoal> written = [];

  @override
  Future<EnglishGoal?> read() async => goal;

  @override
  Future<void> write(EnglishGoal goal) async {
    written.add(goal);
    this.goal = goal;
  }
}

PlacementRecord _placement(int words, CefrLevel cefr) => PlacementRecord(
      takenAt: DateTime.utc(2026, 9, 1),
      result: VocabPlacementResult(
        knownByBand: const [1, 1],
        falseAlarmRate: 0,
        estimatedWords: words,
        xlexScore: words,
        cefr: cefr,
        reliable: true,
      ),
    );

Widget _app({PlacementRecord? placement, _FakeGoals? goals, int dueWords = 0}) {
  final router = GoRouter(
    initialLocation: '/english',
    routes: [
      GoRoute(path: '/english', builder: (_, _) => const EnglishHubScreen()),
      GoRoute(
        path: '/english/placement',
        builder: (_, _) => const Scaffold(body: Text('PLACEMENT')),
      ),
      GoRoute(
        path: '/english/read',
        builder: (_, _) => const Scaffold(body: Text('READ')),
      ),
      GoRoute(
        path: '/english/review',
        builder: (_, _) => const Scaffold(body: Text('REVIEW')),
      ),
      GoRoute(
        path: '/english/recordings',
        builder: (_, _) => const Scaffold(body: Text('RECORDINGS')),
      ),
      GoRoute(
        path: '/english/practice',
        builder: (_, _) => const Scaffold(body: Text('PRACTICE')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      latestPlacementProvider.overrideWith((ref) async => placement),
      englishGoalStoreProvider.overrideWith((ref) async => goals ?? _FakeGoals()),
      reviewDueCountProvider.overrideWith((ref) async => dueWords),
    ],
    child: MaterialApp.router(
      routerConfig: router,
      locale: const Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
}

/// The goal the radio group shows as chosen. Read from the group, because
/// with RadioGroup the tiles no longer carry the selection themselves.
EnglishGoal? _chosen(WidgetTester tester) => tester
    .widget<RadioGroup<EnglishGoal>>(find.byType(RadioGroup<EnglishGoal>))
    .groupValue;

void main() {
  testWidgets('without a placement it says so and offers the test',
      (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.textContaining('Aún no sabes'), findsOneWidget);
    await tester.tap(find.text('Hacer la prueba de nivel'));
    await tester.pumpAndSettle();

    expect(find.text('PLACEMENT'), findsOneWidget);
  });

  testWidgets('with a placement it shows the level and the words',
      (tester) async {
    await tester.pumpWidget(_app(placement: _placement(2900, CefrLevel.b1)));
    await tester.pumpAndSettle();

    expect(find.textContaining('B1'), findsOneWidget);
    expect(find.text('Unas 2900 palabras'), findsOneWidget);
    expect(find.text('Repetir la prueba'), findsOneWidget);
  });

  testWidgets('a beginner reads "fewer than 1000", here too', (tester) async {
    await tester.pumpWidget(_app(placement: _placement(0, CefrLevel.a1)));
    await tester.pumpAndSettle();

    expect(find.text('Menos de 1000 palabras'), findsOneWidget);
  });

  testWidgets('no goal is chosen for the learner', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('¿Para qué quieres el inglés?'), findsOneWidget);
    expect(find.text('Trabajo y clientes'), findsOneWidget);
    expect(find.text('Viajes'), findsOneWidget);
    expect(_chosen(tester), isNull);
  });

  testWidgets('choosing a goal keeps it and shows it chosen', (tester) async {
    final goals = _FakeGoals();
    await tester.pumpWidget(_app(goals: goals));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Vida diaria'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vida diaria'));
    await tester.pumpAndSettle();

    expect(goals.written, [EnglishGoal.everyday]);
    expect(_chosen(tester), EnglishGoal.everyday);
  });

  testWidgets('a goal chosen before, maybe on another device, shows chosen',
      (tester) async {
    await tester.pumpWidget(_app(goals: _FakeGoals(EnglishGoal.travel)));
    await tester.pumpAndSettle();

    expect(_chosen(tester), EnglishGoal.travel);
  });

  testWidgets('reading at your level is one tap away', (tester) async {
    await tester.pumpWidget(_app(
      placement: _placement(2900, CefrLevel.b1),
      goals: _FakeGoals(EnglishGoal.work),
    ));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Leer a tu nivel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leer a tu nivel'));
    await tester.pumpAndSettle();

    expect(find.text('READ'), findsOneWidget);
  });

  testWidgets('the review says how many words are waiting today',
      (tester) async {
    await tester.pumpWidget(_app(dueWords: 7));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.textContaining('Repasar palabras'));
    expect(find.textContaining('7'), findsOneWidget);
    await tester.tap(find.textContaining('Repasar palabras'));
    await tester.pumpAndSettle();

    expect(find.text('REVIEW'), findsOneWidget);
  });

  testWidgets('your recordings are one tap away', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Tus grabaciones'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tus grabaciones'));
    await tester.pumpAndSettle();

    expect(find.text('RECORDINGS'), findsOneWidget);
  });

  testWidgets('talking and writing practice is one tap away', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Practicar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Practicar'));
    await tester.pumpAndSettle();

    expect(find.text('PRACTICE'), findsOneWidget);
  });
}
