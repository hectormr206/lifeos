// What to review today.
//
// Due words first, oldest due first. Then a few NEW words, capped per day: a
// pile of fifty new cards on day three is how review apps get abandoned. And
// each review shows a different saved sentence for the word, because meeting
// it in a new context each time helps it stick (PNAS 2024).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/word_gloss.dart';
import 'package:lifeos/features/english/domain/fsrs.dart';
import 'package:lifeos/features/english/domain/review_queue.dart';

final _now = DateTime.utc(2026, 9, 25, 15);

SavedWord _word(
  String lemma, {
  FsrsCard? card,
  int reviews = 0,
  DateTime? firstReviewAt,
  List<String> sentences = const ['A sentence.'],
}) =>
    SavedWord(
      uuid: lemma,
      lemma: lemma,
      gloss: 'x',
      contexts: [
        for (final s in sentences) SavedContext(sentence: s, source: 'src'),
      ],
      card: card,
      reviews: reviews,
      firstReviewAt: firstReviewAt,
    );

FsrsCard _dueIn(Duration offset) => FsrsCard(
      state: FsrsState.review,
      step: null,
      stability: 5,
      difficulty: 5,
      due: _now.add(offset),
      lastReview: _now.subtract(const Duration(days: 5)),
    );

void main() {
  test('due words come first, the most overdue first', () {
    final queue = buildReviewQueue([
      _word('late', card: _dueIn(const Duration(hours: -1))),
      _word('later', card: _dueIn(const Duration(days: -3))),
      _word('future', card: _dueIn(const Duration(days: 2))),
    ], _now);

    expect(queue.map((i) => i.word.lemma), ['later', 'late']);
  });

  test('new words follow the due ones, as a fresh card', () {
    final queue = buildReviewQueue([
      _word('fresh'),
      _word('due', card: _dueIn(const Duration(minutes: -5))),
    ], _now);

    expect(queue.map((i) => i.word.lemma), ['due', 'fresh']);
    expect(queue.last.card.state, FsrsState.learning);
  });

  test('only a few new words a day', () {
    final queue = buildReviewQueue(
      [for (var i = 0; i < 30; i++) _word('w$i')],
      _now,
    );

    expect(queue, hasLength(kNewWordsPerDay));
  });

  test('new words already started today count against the day', () {
    final started = [
      for (var i = 0; i < kNewWordsPerDay - 2; i++)
        _word('s$i',
            card: _dueIn(const Duration(days: 1)),
            firstReviewAt: _now.subtract(const Duration(hours: 1))),
    ];
    final queue = buildReviewQueue(
      [...started, for (var i = 0; i < 10; i++) _word('n$i')],
      _now,
    );

    expect(queue, hasLength(2));
  });

  test('a session has a ceiling, so it ends', () {
    final queue = buildReviewQueue([
      for (var i = 0; i < 100; i++)
        _word('d$i', card: _dueIn(Duration(minutes: -i - 1))),
    ], _now);

    expect(queue, hasLength(kReviewSessionMax));
  });

  test('each review shows the next saved sentence', () {
    final sentences = ['First.', 'Second.', 'Third.'];
    String sentenceAt(int reviews) => buildReviewQueue([
          _word('w',
              card: _dueIn(const Duration(minutes: -1)),
              reviews: reviews,
              sentences: sentences),
        ], _now)
            .single
            .context
            .sentence;

    expect([for (var r = 0; r < 4; r++) sentenceAt(r)],
        ['First.', 'Second.', 'Third.', 'First.']);
  });

  test('words due later today are not due yet', () {
    final queue = buildReviewQueue(
      [_word('soon', card: _dueIn(const Duration(hours: 2)))],
      _now,
    );

    expect(queue, isEmpty);
  });
}
