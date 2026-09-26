// FSRS-6, the spaced-repetition scheduler, ported from py-fsrs 6.3.2.
//
// FSRS models each card's memory with a stability (days until recall drops to
// 90%) and a difficulty, and schedules the next review for when the chance of
// remembering falls to the desired retention. In the open srs-benchmark it
// predicts recall better than SM-2 (Anki's old default), which is why the
// English review uses it.
//
// This is a line-by-line port of `fsrs/scheduler.py` (py-fsrs 6.3.2, the
// reference implementation). The test holds it to values produced by py-fsrs
// itself, including Python's round-half-to-even for intervals.
//
// py-fsrs is MIT licensed:
//   Copyright (c) 2022 Open Spaced Repetition
//   Permission is hereby granted, free of charge, to any person obtaining a
//   copy of this software and associated documentation files (the
//   "Software"), to deal in the Software without restriction, including
//   without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to permit
//   persons to whom the Software is furnished to do so, subject to the
//   following conditions: The above copyright notice and this permission
//   notice shall be included in all copies or substantial portions of the
//   Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
library;

import 'dart:math' as math;

/// py-fsrs 6.3.2 DEFAULT_PARAMETERS (w0..w20; w20 is the decay).
const List<double> kFsrsDefaultParameters = [
  0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194, 0.001, 1.8722,
  0.1666, 0.796, 1.4835, 0.0614, 0.2629, 1.6483, 0.6014, 1.8729, 0.5425,
  0.0912, 0.0658, 0.1542,
];

const double _stabilityMin = 0.001;
const double _minDifficulty = 1.0;
const double _maxDifficulty = 10.0;

/// How well the learner remembered. Again = forgot.
enum FsrsRating {
  again,
  hard,
  good,
  easy;

  /// 1-4, as in the formulas.
  int get value => index + 1;
}

enum FsrsState { learning, review, relearning }

/// A source of uniform doubles in [0, 1): only the interval fuzz needs it.
abstract interface class RandomSource {
  double nextDouble();
}

class _DartRandom implements RandomSource {
  _DartRandom(this._random);
  final math.Random _random;
  @override
  double nextDouble() => _random.nextDouble();
}

class FsrsCard {
  const FsrsCard({
    required this.state,
    required this.step,
    required this.stability,
    required this.difficulty,
    required this.due,
    required this.lastReview,
  });

  /// A card never reviewed: learning, first step, due now.
  factory FsrsCard.newCard(DateTime now) => FsrsCard(
        state: FsrsState.learning,
        step: 0,
        stability: null,
        difficulty: null,
        due: now,
        lastReview: null,
      );

  final FsrsState state;

  /// Position in the (re)learning steps; null in review.
  final int? step;
  final double? stability;
  final double? difficulty;
  final DateTime due;
  final DateTime? lastReview;
}

/// Python's `round()`: halves go to the even neighbour.
int roundHalfEven(double x) {
  final floor = x.floorToDouble();
  final diff = x - floor;
  if (diff > 0.5) return floor.toInt() + 1;
  if (diff < 0.5) return floor.toInt();
  return floor.toInt().isEven ? floor.toInt() : floor.toInt() + 1;
}

class FsrsScheduler {
  FsrsScheduler({
    this.parameters = kFsrsDefaultParameters,
    this.desiredRetention = 0.9,
    this.learningSteps = const [Duration(minutes: 1), Duration(minutes: 10)],
    this.relearningSteps = const [Duration(minutes: 10)],
    this.maximumInterval = 36500,
    this._fuzz,
  })  : _decay = -parameters[20],
        _factor = math.pow(0.9, 1 / -parameters[20]) - 1;

  /// A scheduler that fuzzes intervals like py-fsrs does by default, so cards
  /// learned together do not all come due on the same day.
  factory FsrsScheduler.fuzzed([math.Random? random]) =>
      FsrsScheduler(fuzz: _DartRandom(random ?? math.Random()));

  final List<double> parameters;
  final double desiredRetention;
  final List<Duration> learningSteps;
  final List<Duration> relearningSteps;
  final int maximumInterval;
  final RandomSource? _fuzz;
  final double _decay;
  final double _factor;

  List<double> get _w => parameters;

  /// Chance of recalling [card] at [at]; 0 for a card never reviewed.
  double retrievability(FsrsCard card, DateTime at) {
    final last = card.lastReview;
    final stability = card.stability;
    if (last == null || stability == null) return 0;
    final elapsed = math.max(0, at.difference(last).inDays);
    return math.pow(1 + _factor * elapsed / stability, _decay).toDouble();
  }

  FsrsCard review(FsrsCard card, FsrsRating rating, DateTime at) {
    final last = card.lastReview;
    final days = last == null ? null : at.difference(last).inDays;
    var state = card.state;
    var step = card.step;
    var stability = card.stability;
    var difficulty = card.difficulty;
    final Duration interval;

    double longTerm() => _nextStability(
        difficulty!, stability!, retrievability(card, at), rating);

    switch (card.state) {
      case FsrsState.learning:
      case FsrsState.relearning:
        final steps = card.state == FsrsState.learning
            ? learningSteps
            : relearningSteps;
        if (card.state == FsrsState.learning &&
            (stability == null || difficulty == null)) {
          stability = _initialStability(rating);
          difficulty = _initialDifficulty(rating, clamp: true);
        } else if (days != null && days < 1) {
          stability = _shortTermStability(stability!, rating);
          difficulty = _nextDifficulty(difficulty!, rating);
        } else {
          stability = longTerm();
          difficulty = _nextDifficulty(difficulty!, rating);
        }

        if (steps.isEmpty ||
            (step! >= steps.length && rating != FsrsRating.again)) {
          state = FsrsState.review;
          step = null;
          interval = Duration(days: _nextInterval(stability));
        } else {
          switch (rating) {
            case FsrsRating.again:
              step = 0;
              interval = steps[0];
            case FsrsRating.hard:
              if (step == 0 && steps.length == 1) {
                interval = steps[0] * 1.5;
              } else if (step == 0 && steps.length >= 2) {
                interval = (steps[0] + steps[1]) * 0.5;
              } else {
                interval = steps[step];
              }
            case FsrsRating.good:
              if (step + 1 == steps.length) {
                state = FsrsState.review;
                step = null;
                interval = Duration(days: _nextInterval(stability));
              } else {
                step += 1;
                interval = steps[step];
              }
            case FsrsRating.easy:
              state = FsrsState.review;
              step = null;
              interval = Duration(days: _nextInterval(stability));
          }
        }

      case FsrsState.review:
        stability = days != null && days < 1
            ? _shortTermStability(stability!, rating)
            : longTerm();
        difficulty = _nextDifficulty(difficulty!, rating);
        if (rating == FsrsRating.again && relearningSteps.isNotEmpty) {
          state = FsrsState.relearning;
          step = 0;
          interval = relearningSteps[0];
        } else {
          interval = Duration(days: _nextInterval(stability));
        }
    }

    final next = _fuzz != null && state == FsrsState.review
        ? _fuzzed(interval, _fuzz)
        : interval;
    return FsrsCard(
      state: state,
      step: step,
      stability: stability,
      difficulty: difficulty,
      due: at.add(next),
      lastReview: at,
    );
  }

  double _clampDifficulty(double d) =>
      d.clamp(_minDifficulty, _maxDifficulty).toDouble();

  double _clampStability(double s) => math.max(s, _stabilityMin);

  double _initialStability(FsrsRating rating) =>
      _clampStability(_w[rating.value - 1]);

  double _initialDifficulty(FsrsRating rating, {required bool clamp}) {
    final d = _w[4] - math.exp(_w[5] * (rating.value - 1)) + 1;
    return clamp ? _clampDifficulty(d) : d;
  }

  int _nextInterval(double stability) {
    final days = (stability / _factor) *
        (math.pow(desiredRetention, 1 / _decay) - 1);
    return math.min(math.max(roundHalfEven(days), 1), maximumInterval);
  }

  double _shortTermStability(double stability, FsrsRating rating) {
    var increase = math.exp(_w[17] * (rating.value - 3 + _w[18])) *
        math.pow(stability, -_w[19]);
    if (rating != FsrsRating.again) increase = math.max(increase, 1.0);
    return _clampStability(stability * increase);
  }

  double _nextDifficulty(double difficulty, FsrsRating rating) {
    final easy = _initialDifficulty(FsrsRating.easy, clamp: false);
    final delta = -(_w[6] * (rating.value - 3));
    final damped = difficulty + (10.0 - difficulty) * delta / 9.0;
    return _clampDifficulty(_w[7] * easy + (1 - _w[7]) * damped);
  }

  double _nextStability(
    double difficulty,
    double stability,
    double retrievability,
    FsrsRating rating,
  ) {
    final next = rating == FsrsRating.again
        ? _nextForgetStability(difficulty, stability, retrievability)
        : _nextRecallStability(difficulty, stability, retrievability, rating);
    return _clampStability(next);
  }

  double _nextForgetStability(double d, double s, double r) {
    final longTerm = _w[11] *
        math.pow(d, -_w[12]) *
        (math.pow(s + 1, _w[13]) - 1) *
        math.exp((1 - r) * _w[14]);
    final shortTerm = s / math.exp(_w[17] * _w[18]);
    return math.min(longTerm, shortTerm);
  }

  double _nextRecallStability(double d, double s, double r, FsrsRating rating) {
    final hardPenalty = rating == FsrsRating.hard ? _w[15] : 1.0;
    final easyBonus = rating == FsrsRating.easy ? _w[16] : 1.0;
    return s *
        (1 +
            math.exp(_w[8]) *
                (11 - d) *
                math.pow(s, -_w[9]) *
                (math.exp((1 - r) * _w[10]) - 1) *
                hardPenalty *
                easyBonus);
  }

  static const List<(double start, double end, double factor)> _fuzzRanges = [
    (2.5, 7.0, 0.15),
    (7.0, 20.0, 0.1),
    (20.0, double.infinity, 0.05),
  ];

  Duration _fuzzed(Duration interval, RandomSource random) {
    final days = interval.inDays;
    if (days < 2.5) return interval;
    var delta = 1.0;
    for (final (start, end, factor) in _fuzzRanges) {
      delta += factor * math.max(math.min(days.toDouble(), end) - start, 0.0);
    }
    var minIvl = roundHalfEven(days - delta);
    var maxIvl = roundHalfEven(days + delta);
    minIvl = math.max(2, minIvl);
    maxIvl = math.min(maxIvl, maximumInterval);
    minIvl = math.min(minIvl, maxIvl);
    final fuzzed = random.nextDouble() * (maxIvl - minIvl + 1) + minIvl;
    return Duration(days: math.min(roundHalfEven(fuzzed), maximumInterval));
  }
}
