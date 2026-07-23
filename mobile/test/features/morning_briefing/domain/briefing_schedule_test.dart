// Proves the pure "Boletín automático" date math: when the next one-shot
// trigger should land (skipping past slots and days whose briefing already
// exists) and whether an automatic run is due right now (incl. the
// already-generated-today guard). Plain DateTimes, no platform channels.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_schedule.dart';

void main() {
  const schedule = BriefingSchedule(enabled: true, hour: 8, minute: 0);

  group('nextRun', () {
    test('targets today when the slot is still ahead', () {
      final now = DateTime(2026, 7, 22, 6, 30);
      expect(schedule.nextRun(now), DateTime(2026, 7, 22, 8, 0));
    });

    test('targets tomorrow when today\'s slot already passed', () {
      final now = DateTime(2026, 7, 22, 8, 0); // exactly at the slot → passed
      expect(schedule.nextRun(now), DateTime(2026, 7, 23, 8, 0));
    });

    test('skips today when a briefing was already generated today', () {
      // 7:50, slot at 8:00 still ahead — but the user generated manually at
      // 7:45, so the reminder must move to tomorrow instead of nagging.
      final now = DateTime(2026, 7, 22, 7, 50);
      final next = schedule.nextRun(now, lastGeneratedAt: DateTime(2026, 7, 22, 7, 45));
      expect(next, DateTime(2026, 7, 23, 8, 0));
    });

    test('yesterday\'s briefing does not skip today\'s slot', () {
      final now = DateTime(2026, 7, 22, 6, 30);
      final next = schedule.nextRun(now, lastGeneratedAt: DateTime(2026, 7, 21, 8, 5));
      expect(next, DateTime(2026, 7, 22, 8, 0));
    });

    test('rolls over month/year boundaries', () {
      final now = DateTime(2026, 12, 31, 9, 0);
      expect(schedule.nextRun(now), DateTime(2027, 1, 1, 8, 0));
    });
  });

  group('shouldRunNow', () {
    test('false when disabled', () {
      const off = BriefingSchedule(enabled: false, hour: 8, minute: 0);
      expect(off.shouldRunNow(DateTime(2026, 7, 22, 9, 0)), isFalse);
    });

    test('false before today\'s slot', () {
      expect(schedule.shouldRunNow(DateTime(2026, 7, 22, 7, 59)), isFalse);
    });

    test('true at/after the slot with no briefing today', () {
      expect(schedule.shouldRunNow(DateTime(2026, 7, 22, 8, 0)), isTrue);
      expect(
        schedule.shouldRunNow(
          DateTime(2026, 7, 22, 22, 0),
          lastGeneratedAt: DateTime(2026, 7, 21, 8, 3),
        ),
        isTrue,
        reason: 'yesterday\'s briefing does not satisfy today',
      );
    });

    test('false when today\'s briefing already exists (guard)', () {
      expect(
        schedule.shouldRunNow(
          DateTime(2026, 7, 22, 9, 0),
          lastGeneratedAt: DateTime(2026, 7, 22, 8, 1),
        ),
        isFalse,
      );
    });
  });

  test('defaults to ENABLED at 8:00 (everything-on default)', () {
    const def = BriefingSchedule();
    expect(def.enabled, isTrue);
    expect(def.hour, 8);
    expect(def.minute, 0);
  });
}
