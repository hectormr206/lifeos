// The daily plan: a habit first, a bigger dose only once the habit exists.
//
// From the ODD doc, "Time and pacing": 15 minutes a day for the first two
// weeks, 30 in blocks until about day 66 (the median time to automaticity in
// Lally et al. 2010), then more. Five minutes always counts as a day done.
// Never miss twice: after a missed day, the plan offers only the floor. A
// bigger dose is PROPOSED once the current one was sustained, never imposed.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/daily_plan.dart';

final _today = DateTime(2026, 11, 10, 9);

StudyActivity _did(int daysAgo, int minutes, [ActivityKind kind = ActivityKind.review]) =>
    StudyActivity(
      kind: kind,
      at: _today.subtract(Duration(days: daysAgo)),
      minutes: minutes,
    );

void main() {
  group('which phase', () {
    test('the first two weeks are the start', () {
      expect(phaseFor(daysSinceStart: 0), StudyPhase.start);
      expect(phaseFor(daysSinceStart: 13), StudyPhase.start);
    });

    test('then building the habit, until about day 66', () {
      expect(phaseFor(daysSinceStart: 14), StudyPhase.build);
      expect(phaseFor(daysSinceStart: 65), StudyPhase.build);
    });

    test('then cruising', () {
      expect(phaseFor(daysSinceStart: 66), StudyPhase.cruise);
    });

    test('the minutes each phase asks for', () {
      expect(StudyPhase.start.minutes, 15);
      expect(StudyPhase.build.minutes, 30);
      expect(StudyPhase.cruise.minutes, greaterThan(30));
    });
  });

  group('today', () {
    test('five minutes already count as a day done', () {
      final day = todayStatus([_did(0, 5)], now: _today);

      expect(day.minutesToday, 5);
      expect(day.done, isTrue);
    });

    test('four minutes are not yet a day', () {
      expect(todayStatus([_did(0, 4)], now: _today).done, isFalse);
    });

    test('a missed yesterday puts only the floor on the table today', () {
      final day = todayStatus([_did(2, 20)], now: _today);

      expect(day.missedYesterday, isTrue);
      expect(day.floorOnly, isTrue);
    });

    test('no activity at all yet is a first day, not a missed one', () {
      final day = todayStatus(const [], now: _today);

      expect(day.missedYesterday, isFalse);
      expect(day.floorOnly, isFalse);
    });

    test('the week counts days practised, not a fragile streak', () {
      final day = todayStatus([
        _did(0, 6),
        _did(1, 10),
        _did(3, 15),
        _did(3, 15), // same day twice is still one day
        _did(9, 30), // last week does not count
      ], now: _today);

      expect(day.daysThisWeek, 3);
    });
  });

  group('the plan for today', () {
    test('the start is one short block: review and one reading', () {
      final plan = planFor(StudyPhase.start, floorOnly: false);

      expect(plan.map((s) => s.kind),
          [ActivityKind.review, ActivityKind.read]);
      expect(plan.fold<int>(0, (m, s) => m + s.minutes), 15);
    });

    test('building adds speaking and talking or writing', () {
      final kinds = planFor(StudyPhase.build, floorOnly: false).map((s) => s.kind);

      expect(kinds, containsAll([ActivityKind.speak, ActivityKind.talk]));
    });

    test('the floor day is one five-minute thing', () {
      final plan = planFor(StudyPhase.build, floorOnly: true);

      expect(plan, hasLength(1));
      expect(plan.single.minutes, kFloorMinutes);
    });
  });

  group('proposing more, never imposing it', () {
    test('a sustained start proposes building', () {
      final history = [for (var d = 1; d <= 14; d++) _did(d, 15)];

      expect(
        proposedPhase(StudyPhase.start, history, now: _today),
        StudyPhase.build,
      );
    });

    test('a shaky start does not', () {
      final history = [for (var d = 1; d <= 14; d += 3) _did(d, 15)];

      expect(proposedPhase(StudyPhase.start, history, now: _today), isNull);
    });

    test('cruise has nothing above it', () {
      final history = [for (var d = 1; d <= 14; d++) _did(d, 60)];

      expect(proposedPhase(StudyPhase.cruise, history, now: _today), isNull);
    });
  });

  group('measuring again', () {
    test('a month after the last placement it is time to measure progress', () {
      expect(
        reassessmentDue(_today.subtract(const Duration(days: 31)), now: _today),
        isTrue,
      );
      expect(
        reassessmentDue(_today.subtract(const Duration(days: 10)), now: _today),
        isFalse,
      );
    });

    test('with no placement at all, the placement itself is the first step', () {
      expect(reassessmentDue(null, now: _today), isTrue);
    });
  });
}
