// Proves the DETERMINISTIC prediction engine (no model): pure functions over a
// fixture fact list detect recurring sequences, streak breaks, trends and lagged
// correlations, and empty input yields empty output.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/insights/domain/prediction_engine.dart';

void main() {
  final now = DateTime.utc(2026, 7, 22, 12, 0);
  DateTime daysAgo(int n) => now.subtract(Duration(days: n));
  DateTime utcDay(int n) {
    final d = daysAgo(n);
    return DateTime.utc(d.year, d.month, d.day);
  }

  FactSample sleep(int n, double hours) =>
      FactSample(timestamp: daysAgo(n), domain: 'health', type: 'sleep_hours', value: hours);
  FactSample exercise(int n) =>
      FactSample(timestamp: daysAgo(n), domain: 'exercise', type: 'exercise');
  FactSample conflict(int n) =>
      FactSample(timestamp: daysAgo(n), domain: 'relationships', type: 'conflict');
  FactSample spend(int n, double amount) =>
      FactSample(timestamp: daysAgo(n), domain: 'finance', type: 'big_purchase', value: amount);

  group('detectPatterns (composition)', () {
    test('empty input → empty output', () {
      expect(detectPatterns(const <FactSample>[], now: now), isEmpty);
    });

    test('surfaces sleep deficit over recent low readings', () {
      final facts = <FactSample>[sleep(1, 5.0), sleep(2, 5.5), sleep(3, 6.0)];
      final patterns = detectPatterns(facts, now: now);
      final p = patterns.firstWhere((p) => p.kind == 'sleep_deficit');
      expect(p.severity, 'warning');
      expect(p.data['samples'], 3);
    });
  });

  group('sleepDeficit', () {
    test('fires when avg < threshold with ≥3 samples', () {
      final p = sleepDeficit(<FactSample>[sleep(1, 5), sleep(2, 6), sleep(3, 6)], now: now);
      expect(p, isNotNull);
      expect(p!.data['avg_hours'], closeTo(5.67, 0.01));
    });

    test('null with fewer than 3 samples', () {
      expect(sleepDeficit(<FactSample>[sleep(1, 4), sleep(2, 4)], now: now), isNull);
    });

    test('null when average is healthy', () {
      final p = sleepDeficit(<FactSample>[sleep(1, 8), sleep(2, 7.5), sleep(3, 8)], now: now);
      expect(p, isNull);
    });
  });

  group('recurringSequence', () {
    test('detects a type recurring on ≥threshold distinct days', () {
      final p = recurringSequence(
        <FactSample>[conflict(1), conflict(4), conflict(9)],
        now: now,
        type: 'conflict',
        threshold: 2,
        activityLabel: 'conflicto',
      );
      expect(p, isNotNull);
      expect(p!.kind, 'recurring_sequence');
      expect(p.data['distinct_days'], 3);
    });

    test('same-day duplicates count once (distinct days)', () {
      final p = recurringSequence(
        <FactSample>[conflict(1), conflict(1), conflict(1)],
        now: now,
        type: 'conflict',
        threshold: 2,
      );
      expect(p, isNull); // only one distinct day
    });
  });

  group('currentStreak / brokenStreak', () {
    test('currentStreak counts consecutive days ending on the most recent', () {
      final days = <DateTime>{utcDay(4), utcDay(5), utcDay(6), utcDay(9)};
      // Most recent is utcDay(4); 4,5,6 consecutive → streak 3 (7 missing).
      expect(currentStreak(days), 3);
    });

    test('empty set → 0', () => expect(currentStreak(const <DateTime>{}), 0));

    test('broken streak: ≥3 consecutive days then a 2–7 day gap', () {
      // Exercise on days 4,5,6 ago (3-day streak), nothing since → gap of 4.
      final facts = <FactSample>[exercise(4), exercise(5), exercise(6)];
      final p = brokenStreak(facts, now: now, type: 'exercise', activityLabel: 'ejercicio');
      expect(p, isNotNull);
      expect(p!.data['prior_streak'], 3);
      expect(p.data['gap_days'], 4);
    });

    test('no break when the streak is still active (gap < 2)', () {
      final facts = <FactSample>[exercise(0), exercise(1), exercise(2)];
      expect(brokenStreak(facts, now: now, type: 'exercise'), isNull);
    });
  });

  group('trendAcceleration', () {
    test('fires when the recent half-window outspends the prior by the ratio', () {
      // days 14-window: half=7. Recent (0-6): 300. Prior (7-13): 100.
      final facts = <FactSample>[spend(1, 300), spend(10, 100)];
      final p = trendAcceleration(facts, now: now, domain: 'finance');
      expect(p, isNotNull);
      expect(p!.data['delta_pct'], 200);
    });

    test('null below the prior-total floor', () {
      final facts = <FactSample>[spend(1, 50), spend(10, 10)];
      expect(trendAcceleration(facts, now: now, domain: 'finance'), isNull);
    });
  });

  group('detectLaggedCorrelation (pure primitive)', () {
    test('detects trigger→event correlation within the lag window', () {
      // 3 poor-sleep trigger days, each followed (lag ≤2) by an event; the two
      // non-trigger days have no event → strong ratio.
      final result = detectLaggedCorrelation(
        triggerDays: <DateTime>{utcDay(10), utcDay(20), utcDay(30)},
        nonTriggerDays: <DateTime>{utcDay(40), utcDay(50)},
        eventDays: <DateTime>{utcDay(9), utcDay(19), utcDay(29)},
      );
      expect(result, isNotNull);
      expect(result!.eventsAfterTrigger, 3);
      expect(result.eventsAfterNonTrigger, 0);
      expect(result.rateRatio, greaterThanOrEqualTo(kMinRateRatio));
    });

    test('null when trigger days below the minimum', () {
      final result = detectLaggedCorrelation(
        triggerDays: <DateTime>{utcDay(10)},
        nonTriggerDays: <DateTime>{utcDay(20)},
        eventDays: <DateTime>{utcDay(9), utcDay(8)},
      );
      expect(result, isNull);
    });

    test('null when the ratio is too weak (events under non-triggers too)', () {
      final result = detectLaggedCorrelation(
        triggerDays: <DateTime>{utcDay(10), utcDay(20), utcDay(30)},
        nonTriggerDays: <DateTime>{utcDay(40), utcDay(50), utcDay(60)},
        eventDays: <DateTime>{utcDay(9), utcDay(39), utcDay(49)},
      );
      expect(result, isNull);
    });
  });
}
