// Choosing what to read today: a few passages at the learner's level.
//
// It needs two things first, the level and the goal, and says which one is
// missing instead of guessing. Fetching needs the internet, the only part of
// the English feature that leaves the device, and the screen says so.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/english_placement_repository.dart';
import 'package:lifeos/features/english/data/wikimedia_reading.dart';
import 'package:lifeos/features/english/domain/english_goal.dart';
import 'package:lifeos/features/english/domain/lexical_coverage.dart';
import 'package:lifeos/features/english/domain/reading_passages.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';
import 'package:lifeos/features/english/domain/vocab_placement_session.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/english/presentation/english_reading_list_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

final _index = WordIndex(const VocabBank(
  bands: [
    ['dog', 'the', 'ground', 'they', 'sleep', 'a', 'lot'],
    ['sniff'],
  ],
  pseudowords: [],
));

final _placement = PlacementRecord(
  takenAt: DateTime.utc(2026, 9, 1),
  result: const VocabPlacementResult(
    knownByBand: [1.0, 0.0],
    falseAlarmRate: 0,
    estimatedWords: 1000,
    xlexScore: 1000,
    cefr: CefrLevel.a1,
    reliable: true,
  ),
);

PickedReading _reading(String title, String text) => PickedReading(
      article: ReadingArticle(
          site: 'simple.wikipedia.org', title: title, license: 'CC BY-SA'),
      ranked: RankedPassage(
        passage: Passage(text: text, section: ''),
        report: measureCoverage(text, _index, knownByBand: const [1.0, 0.0]),
      ),
    );

Widget _app({
  PlacementRecord? placement,
  EnglishGoal? goal,
  Future<List<PickedReading>> Function()? list,
}) =>
    ProviderScope(
      overrides: [
        latestPlacementProvider.overrideWith((ref) async => placement),
        englishGoalProvider.overrideWith((ref) async => goal),
        wordIndexProvider.overrideWith((ref) async => _index),
        readingListProvider.overrideWith(
            (ref) => list?.call() ?? Future.value(const <PickedReading>[])),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EnglishReadingListScreen(),
      ),
    );

void main() {
  testWidgets('without a placement it asks for the test first',
      (tester) async {
    await tester.pumpWidget(_app(goal: EnglishGoal.everyday));
    await tester.pumpAndSettle();

    expect(find.textContaining('Primero haz la prueba'), findsOneWidget);
  });

  testWidgets('without a goal it asks for the goal first', (tester) async {
    await tester.pumpWidget(_app(placement: _placement));
    await tester.pumpAndSettle();

    expect(find.textContaining('Primero elige'), findsOneWidget);
  });

  testWidgets('while fetching it says what it is doing, and that it needs '
      'the internet', (tester) async {
    final never = Completer<List<PickedReading>>();
    await tester.pumpWidget(_app(
      placement: _placement,
      goal: EnglishGoal.everyday,
      list: () => never.future,
    ));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Buscando lecturas'), findsOneWidget);
    expect(find.textContaining('internet'), findsWidgets);
  });

  testWidgets('a rate limit says how long to wait, and offers to retry',
      (tester) async {
    await tester.pumpWidget(_app(
      placement: _placement,
      goal: EnglishGoal.everyday,
      list: () => Future.error(const RateLimited(Duration(seconds: 30))),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('30'), findsOneWidget);
    expect(find.text('Buscar otras'), findsOneWidget);
  });

  testWidgets('no connection is said plainly', (tester) async {
    await tester.pumpWidget(_app(
      placement: _placement,
      goal: EnglishGoal.everyday,
      list: () => Future.error(Exception('offline')),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('¿Hay conexión'), findsOneWidget);
  });

  testWidgets('each passage shows its article, its fit and its new words; '
      'tapping opens it', (tester) async {
    await tester.pumpWidget(_app(
      placement: _placement,
      goal: EnglishGoal.everyday,
      list: () async => [_reading('Dog', 'Dogs sniffed the ground.')],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Dog'), findsOneWidget);
    expect(find.textContaining('Difícil'), findsOneWidget);
    expect(find.textContaining('1 palabra'), findsOneWidget);

    await tester.tap(find.text('Dog'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Toca cualquier palabra'), findsOneWidget);
  });

  testWidgets('nothing found is said, with a way to try again',
      (tester) async {
    await tester.pumpWidget(_app(
      placement: _placement,
      goal: EnglishGoal.everyday,
      list: () async => const [],
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('No encontré'), findsOneWidget);
    expect(find.text('Buscar otras'), findsOneWidget);
  });

  testWidgets('your own audio or video can be imported from here',
      (tester) async {
    await tester.pumpWidget(_app(placement: _placement, goal: EnglishGoal.everyday));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Importar audio o video'));
    await tester.pumpAndSettle();

    expect(find.text('Tu audio o video'), findsOneWidget);
  });
}
