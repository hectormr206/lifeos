// Reviewing saved words: the word in its sentence, then how well you knew it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/word_gloss.dart';
import 'package:lifeos/features/english/domain/fsrs.dart';
import 'package:lifeos/features/english/domain/lexical_coverage.dart';
import 'package:lifeos/features/english/domain/vocab_placement_session.dart';
import 'package:lifeos/features/english/presentation/english_providers.dart';
import 'package:lifeos/features/english/presentation/english_review_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

class _FakeStore implements ReviewStore {
  _FakeStore(this.words);

  final List<SavedWord> words;
  final List<(String, FsrsCard)> recorded = [];
  bool fail = false;

  @override
  Future<List<SavedWord>> all() async => words;

  @override
  Future<void> recordReview(String uuid, FsrsCard card,
      {required DateTime at}) async {
    if (fail) throw Exception('disk full');
    recorded.add((uuid, card));
  }
}

SavedWord _word(String lemma, String sentence, {String? gloss = 'significado'}) =>
    SavedWord(
      uuid: lemma,
      lemma: lemma,
      gloss: gloss,
      contexts: [SavedContext(sentence: sentence, source: 'src')],
    );

Widget _app(_FakeStore store) => ProviderScope(
      overrides: [
        reviewStoreProvider.overrideWith((ref) async => store),
        fsrsSchedulerProvider.overrideWithValue(FsrsScheduler()),
        wordIndexProvider.overrideWith((ref) async => WordIndex(const VocabBank(
              bands: [
                ['sniff', 'bark', 'dog'],
              ],
              pseudowords: [],
            ))),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: EnglishReviewScreen(),
      ),
    );

void main() {
  testWidgets('with nothing saved it says how words get here',
      (tester) async {
    await tester.pumpWidget(_app(_FakeStore([])));
    await tester.pumpAndSettle();

    expect(find.textContaining('Guarda palabras mientras lees'), findsOneWidget);
  });

  testWidgets('it asks for the meaning in the sentence, then shows it with '
      'when each answer brings it back', (tester) async {
    await tester.pumpWidget(
        _app(_FakeStore([_word('sniff', 'Dogs sniffed the ground.')])));
    await tester.pumpAndSettle();

    expect(find.text('sniff'), findsOneWidget);
    expect(find.textContaining('Dogs'), findsOneWidget);
    expect(find.text('significado'), findsNothing);

    await tester.tap(find.text('Mostrar'));
    await tester.pumpAndSettle();

    expect(find.text('significado'), findsOneWidget);
    expect(find.textContaining('Otra vez'), findsOneWidget);
    expect(find.textContaining('Bien'), findsOneWidget);
    expect(find.textContaining('1 min'), findsOneWidget);
  });

  testWidgets('answering records the review and moves on', (tester) async {
    final store = _FakeStore([
      _word('sniff', 'Dogs sniff.'),
      _word('bark', 'Dogs bark.'),
    ]);
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mostrar'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Fácil'));
    await tester.pumpAndSettle();

    expect(store.recorded.single.$1, 'sniff');
    expect(store.recorded.single.$2.state, FsrsState.review);
    expect(find.text('bark'), findsOneWidget);
  });

  testWidgets('"again" brings the word back in the same session',
      (tester) async {
    final store = _FakeStore([_word('sniff', 'Dogs sniff.')]);
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mostrar'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Otra vez'));
    await tester.pumpAndSettle();

    expect(find.text('sniff'), findsOneWidget, reason: 'it comes back');
    expect(find.text('Mostrar'), findsOneWidget);
  });

  testWidgets('the end says how many were reviewed', (tester) async {
    // "Fácil" graduates a new word to review. "Bien" on a NEW word only moves
    // it to the 10-minute learning step, so it would come back this session,
    // as in Anki and py-fsrs.
    await tester.pumpWidget(_app(_FakeStore([_word('sniff', 'Dogs sniff.')])));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mostrar'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Fácil'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Repasaste 1'), findsOneWidget);
  });

  testWidgets('a review that cannot be saved is said, and the card stays',
      (tester) async {
    final store = _FakeStore([_word('sniff', 'Dogs sniff.')])..fail = true;
    await tester.pumpWidget(_app(store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mostrar'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Bien'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No se pudo guardar'), findsOneWidget);
    expect(find.text('sniff'), findsOneWidget);
  });

  test('intervals read like a person would say them', () {
    expect(describeInterval(const Duration(minutes: 1)), (1, IntervalUnit.minutes));
    expect(describeInterval(const Duration(minutes: 330)), (5, IntervalUnit.hours));
    expect(describeInterval(const Duration(days: 2)), (2, IntervalUnit.days));
    expect(describeInterval(const Duration(days: 75)), (2, IntervalUnit.months));
    expect(describeInterval(const Duration(days: 800)), (2, IntervalUnit.years));
  });
}
