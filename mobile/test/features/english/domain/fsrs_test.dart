// FSRS-6, ported from py-fsrs 6.3.2 and held to it.
//
// Every expected value below was produced by the reference implementation
// itself (py-fsrs 6.3.2, fuzzing off) on 2026-09-25, not written by hand: the
// same parity approach this repo uses between its Python and Dart code. If
// one of these drifts, the port no longer schedules like FSRS.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/fsrs.dart';

class _Row {
  const _Row(
    this.rating,
    this.at,
    this.state,
    this.step,
    this.stability,
    this.difficulty,
    this.due,
  );
  final String rating;
  final String at;
  final String state;
  final int? step;
  final double stability;
  final double difficulty;
  final String due;
}

const Map<String, List<_Row>> _reference = {
  'good_path': [
    _Row(
      'good',
      '2026-09-25T12:00:00+00:00',
      'Learning',
      1,
      2.3065,
      2.118103970459016,
      '2026-09-25T12:10:00+00:00',
    ),
    _Row(
      'good',
      '2026-09-25T12:10:00+00:00',
      'Review',
      null,
      2.3065,
      2.111214235785395,
      '2026-09-27T12:10:00+00:00',
    ),
    _Row(
      'good',
      '2026-09-27T12:10:00+00:00',
      'Review',
      null,
      10.971048263078135,
      2.1043313908464483,
      '2026-10-08T12:10:00+00:00',
    ),
    _Row(
      'good',
      '2026-10-08T12:10:00+00:00',
      'Review',
      null,
      46.316858440073425,
      2.0974554287524403,
      '2026-11-23T12:10:00+00:00',
    ),
    _Row(
      'good',
      '2026-11-23T12:10:00+00:00',
      'Review',
      null,
      162.99981577472244,
      2.0905863426205262,
      '2027-05-05T12:10:00+00:00',
    ),
  ],
  'lapse': [
    _Row(
      'good',
      '2026-09-25T12:00:00+00:00',
      'Learning',
      1,
      2.3065,
      2.118103970459016,
      '2026-09-25T12:10:00+00:00',
    ),
    _Row(
      'good',
      '2026-09-25T12:10:00+00:00',
      'Review',
      null,
      2.3065,
      2.111214235785395,
      '2026-09-27T12:10:00+00:00',
    ),
    _Row(
      'good',
      '2026-09-27T12:10:00+00:00',
      'Review',
      null,
      10.971048263078135,
      2.1043313908464483,
      '2026-10-08T12:10:00+00:00',
    ),
    _Row(
      'again',
      '2026-10-08T12:10:00+00:00',
      'Relearning',
      0,
      1.53901253028147,
      7.389975788014609,
      '2026-10-08T12:20:00+00:00',
    ),
    _Row(
      'good',
      '2026-10-08T12:20:00+00:00',
      'Review',
      null,
      1.5718415897918614,
      7.377814181523433,
      '2026-10-10T12:20:00+00:00',
    ),
    _Row(
      'good',
      '2026-10-10T12:20:00+00:00',
      'Review',
      null,
      4.934768723890772,
      7.365664736638748,
      '2026-10-15T12:20:00+00:00',
    ),
  ],
  'hard_learning': [
    _Row(
      'again',
      '2026-09-25T12:00:00+00:00',
      'Learning',
      0,
      0.212,
      6.4133,
      '2026-09-25T12:01:00+00:00',
    ),
    _Row(
      'again',
      '2026-09-25T12:01:00+00:00',
      'Learning',
      0,
      0.08335671711031604,
      8.806304468856837,
      '2026-09-25T12:02:00+00:00',
    ),
    _Row(
      'hard',
      '2026-09-25T12:02:00+00:00',
      'Learning',
      0,
      0.08335671711031604,
      9.192797649512254,
      '2026-09-25T12:07:30+00:00',
    ),
    _Row(
      'good',
      '2026-09-25T12:07:30+00:00',
      'Learning',
      1,
      0.10314065007785231,
      9.17883322115958,
      '2026-09-25T12:17:30+00:00',
    ),
    _Row(
      'good',
      '2026-09-25T12:17:30+00:00',
      'Review',
      null,
      0.12584423732556518,
      9.164882757235258,
      '2026-09-26T12:17:30+00:00',
    ),
    _Row(
      'hard',
      '2026-09-26T12:17:30+00:00',
      'Review',
      null,
      0.45040912658385546,
      9.43083862708609,
      '2026-09-27T12:17:30+00:00',
    ),
  ],
  'easy_then_late': [
    _Row(
      'easy',
      '2026-09-25T12:00:00+00:00',
      'Review',
      null,
      8.2956,
      1.0,
      '2026-10-03T12:00:00+00:00',
    ),
    _Row(
      'good',
      '2026-10-08T12:00:00+00:00',
      'Review',
      null,
      50.873643161718135,
      1.0,
      '2026-11-28T12:00:00+00:00',
    ),
    _Row(
      'easy',
      '2026-12-18T12:00:00+00:00',
      'Review',
      null,
      386.22935090018,
      1.0,
      '2028-01-08T12:00:00+00:00',
    ),
    _Row(
      'hard',
      '2028-01-08T12:00:00+00:00',
      'Review',
      null,
      849.9480987659684,
      4.010608969296839,
      '2030-05-07T12:00:00+00:00',
    ),
  ],
  'same_day': [
    _Row(
      'good',
      '2026-09-25T12:00:00+00:00',
      'Learning',
      1,
      2.3065,
      2.118103970459016,
      '2026-09-25T12:10:00+00:00',
    ),
    _Row(
      'good',
      '2026-09-25T12:10:00+00:00',
      'Review',
      null,
      2.3065,
      2.111214235785395,
      '2026-09-27T12:10:00+00:00',
    ),
    _Row(
      'good',
      '2026-09-25T12:40:00+00:00',
      'Review',
      null,
      2.3065,
      2.1043313908464483,
      '2026-09-27T12:40:00+00:00',
    ),
    _Row(
      'good',
      '2026-09-27T12:40:00+00:00',
      'Review',
      null,
      10.977757474408312,
      2.0974554287524403,
      '2026-10-08T12:40:00+00:00',
    ),
  ],
};

FsrsRating _rating(String name) => FsrsRating.values.byName(name);

void main() {
  final scheduler = FsrsScheduler();

  _reference.forEach((name, rows) {
    test('matches py-fsrs: $name', () {
      var card = FsrsCard.newCard(DateTime.parse(rows.first.at));
      for (final row in rows) {
        card = scheduler.review(
          card,
          _rating(row.rating),
          DateTime.parse(row.at),
        );
        final where = '$name after ${row.rating} at ${row.at}';
        expect(card.state.name, row.state.toLowerCase(), reason: where);
        expect(card.step, row.step, reason: where);
        expect(card.stability, closeTo(row.stability, 1e-9), reason: where);
        expect(card.difficulty, closeTo(row.difficulty, 1e-9), reason: where);
        expect(card.due, DateTime.parse(row.due), reason: where);
      }
    });
  });

  test('retrievability decays like py-fsrs', () {
    final start = DateTime.utc(2026, 9, 25, 12);
    var card = scheduler.review(
      FsrsCard.newCard(start),
      FsrsRating.good,
      start,
    );
    card = scheduler.review(card, FsrsRating.good, card.due);
    expect(card.stability, closeTo(2.3065, 1e-9));

    const expected = {
      0: 1.0,
      1: 0.9468474993825461,
      3: 0.8809479557659419,
      10: 0.7743669167614039,
      30: 0.6675263338730357,
    };
    expected.forEach((days, r) {
      final at = card.lastReview!.add(Duration(days: days));
      expect(
        scheduler.retrievability(card, at),
        closeTo(r, 1e-12),
        reason: '$days days',
      );
    });
  });

  test('a card never reviewed has nothing to recall', () {
    final card = FsrsCard.newCard(DateTime.utc(2026, 9, 25));
    expect(scheduler.retrievability(card, DateTime.utc(2026, 9, 26)), 0);
  });

  test('fuzz spreads due dates exactly like py-fsrs', () {
    // Reference: py-fsrs 6.3.2 with fuzzing on and its random() pinned to
    // 0.999, five "good" reviews each taken on the day it came due.
    final fuzzy = FsrsScheduler(fuzz: _FixedRandom(0.999));
    const dues = [
      '2026-09-25T12:10:00Z',
      '2026-09-27T12:10:00Z',
      '2026-10-11T12:10:00Z',
      '2026-12-09T12:10:00Z',
      '2027-07-04T12:10:00Z',
    ];
    final start = DateTime.utc(2026, 9, 25, 12);
    var card = FsrsCard.newCard(start);
    for (final due in dues) {
      card = fuzzy.review(
        card,
        FsrsRating.good,
        card.lastReview == null ? start : card.due,
      );
      expect(card.due, DateTime.parse(due));
    }
    expect(card.stability, closeTo(194.181153, 1e-6));
  });

  test('rounding a half-day interval matches Python (half to even)', () {
    expect(roundHalfEven(2.5), 2);
    expect(roundHalfEven(3.5), 4);
    expect(roundHalfEven(2.4), 2);
    expect(roundHalfEven(2.6), 3);
  });
}

class _FixedRandom implements RandomSource {
  _FixedRandom(this.value);
  final double value;
  @override
  double nextDouble() => value;
}
