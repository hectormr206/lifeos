// The vocabulary placement, as the learner lives it.
//
// Three promises: it warns about the invented words BEFORE the first one
// appears (a trap you were not told about feels like a trick), it never
// presents a guessed result as a level, and every attempt is kept.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/english_placement_repository.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';
import 'package:lifeos/features/english/domain/vocab_placement_session.dart';
import 'package:lifeos/features/english/presentation/english_placement_screen.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';

class _FakeHistory implements PlacementHistory {
  _FakeHistory([this.latest]);

  PlacementRecord? latest;
  final List<VocabPlacementResult> saved = [];

  @override
  Future<void> save(VocabPlacementResult result, {required DateTime takenAt}) async =>
      saved.add(result);

  @override
  Future<PlacementRecord?> latestReliable() async => latest;
}

/// Five bands of ten words ("b0w0"...), and invented words starting with "p".
final _bank = VocabBank(
  bands: [
    for (var b = 0; b < 5; b++) [for (var i = 0; i < 10; i++) 'b${b}w$i'],
  ],
  pseudowords: [for (var i = 0; i < 50; i++) 'p$i'],
);

Widget _app(_FakeHistory history) => ProviderScope(
      overrides: [
        vocabBankProvider.overrideWith((ref) async => _bank),
        placementHistoryProvider.overrideWith((ref) async => history),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EnglishPlacementScreen(),
      ),
    );

/// Answers until the result shows. [knows] decides each word.
Future<void> _answerAll(
  WidgetTester tester,
  bool Function(String word) knows,
) async {
  final word = find.byKey(const Key('english-placement-word'));
  while (word.evaluate().isNotEmpty) {
    final text = tester.widget<Text>(word).data!;
    await tester.tap(find.byKey(
      Key(knows(text) ? 'english-placement-yes' : 'english-placement-no'),
    ));
    await tester.pump();
  }
}

bool _honest(String word) => !word.startsWith('p');

void main() {
  testWidgets('it warns about the invented words before the first one',
      (tester) async {
    await tester.pumpWidget(_app(_FakeHistory()));
    await tester.pumpAndSettle();

    expect(find.textContaining('inventadas'), findsOneWidget);
    expect(find.byKey(const Key('english-placement-word')), findsNothing);
    expect(find.text('Empezar'), findsOneWidget);
  });

  testWidgets('it shows the last reliable level before a new attempt',
      (tester) async {
    final history = _FakeHistory(PlacementRecord(
      takenAt: DateTime.utc(2026, 9, 1),
      result: const VocabPlacementResult(
        knownByBand: [1, 1, 0.9],
        falseAlarmRate: 0,
        estimatedWords: 2900,
        xlexScore: 2900,
        cefr: CefrLevel.b1,
        reliable: true,
      ),
    ));
    await tester.pumpWidget(_app(history));
    await tester.pumpAndSettle();

    expect(find.textContaining('B1'), findsOneWidget);
    expect(find.textContaining('2900'), findsOneWidget);
  });

  testWidgets('an honest learner gets a level, and it is kept',
      (tester) async {
    final history = _FakeHistory();
    await tester.pumpWidget(_app(history));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Empezar'));
    await tester.pump();
    await _answerAll(tester, _honest);
    await tester.pumpAndSettle();

    expect(find.textContaining('5000'), findsOneWidget);
    expect(find.textContaining('C2'), findsOneWidget);
    expect(find.textContaining('no es fiable'), findsNothing);
    expect(history.saved.single.reliable, isTrue);
  });

  testWidgets('saying yes to everything is not presented as a level',
      (tester) async {
    final history = _FakeHistory();
    await tester.pumpWidget(_app(history));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Empezar'));
    await tester.pump();
    await _answerAll(tester, (word) => true);
    await tester.pumpAndSettle();

    expect(find.textContaining('no es fiable'), findsOneWidget);
    expect(find.textContaining('C2'), findsNothing);
    // Kept anyway: the history is the truth, flagged as such.
    expect(history.saved.single.reliable, isFalse);
  });

  testWidgets('the test can be taken again from the result', (tester) async {
    await tester.pumpWidget(_app(_FakeHistory()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Empezar'));
    await tester.pump();
    await _answerAll(tester, (word) => true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repetir la prueba'));
    await tester.pump();

    expect(find.byKey(const Key('english-placement-word')), findsOneWidget);
  });
}
