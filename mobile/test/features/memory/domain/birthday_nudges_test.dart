// Birthdays have to REACH you, not wait to be found.
//
// Reported: "no sé cómo usarlo o dónde se ve, o si me van a llegar
// notificaciones o qué show, estoy en blanco en esto". Measured on the test
// Pixel: the birthday list existed and was correct, and it was only visible if
// you opened Registrar por categoría → Relaciones. A birthday you have to go
// looking for is a birthday you already missed.
//
// So this decides WHAT to schedule and WHEN, as a pure function. Two nudges:
// a few days ahead (time to buy something, book something, write something)
// and the morning of. Nothing is written to the graph — a notification does
// not need to be a stored row, and one per person per year would multiply
// across every device that syncs.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/birthday_nudges.dart';
import 'package:lifeos/features/memory/domain/birthdays.dart';

void main() {
  // A Wednesday, 08:00 local.
  final now = DateTime(2026, 8, 19, 8);

  PersonBirthday person(String name, DateTime born, {String? relation}) =>
      PersonBirthday(name: name, birthDate: born, relation: relation);

  group('what gets scheduled', () {
    test('a birthday a few days away gets an early warning and a day-of', () {
      final nudges = birthdayNudges(
        [person('Sofía', DateTime(2019, 8, 24))],
        now: now,
      );

      expect(nudges.map((n) => n.kind).toSet(),
          {BirthdayNudgeKind.ahead, BirthdayNudgeKind.dayOf});
    });

    test('the early warning lands before the day, not after', () {
      final nudges = birthdayNudges(
        [person('Sofía', DateTime(2019, 8, 24))],
        now: now,
      );
      final ahead = nudges.firstWhere((n) => n.kind == BirthdayNudgeKind.ahead);
      final dayOf = nudges.firstWhere((n) => n.kind == BirthdayNudgeKind.dayOf);

      expect(ahead.at.isBefore(dayOf.at), isTrue);
      expect(ahead.at.isAfter(now), isTrue,
          reason: 'a notification scheduled in the past never fires');
    });

    test('a birthday TODAY still gets its day-of nudge', () {
      // The commonest way to miss one: you open the app that morning.
      final nudges = birthdayNudges(
        [person('Ana', DateTime(1990, 8, 19))],
        now: DateTime(2026, 8, 19, 6),
      );

      expect(nudges.any((n) => n.kind == BirthdayNudgeKind.dayOf), isTrue);
    });

    test('a birthday today, already past the hour, is not scheduled', () {
      // 09:00 has gone. Scheduling it would either fire instantly at 15:00 or
      // silently never fire, and both are worse than the screen you can open.
      final nudges = birthdayNudges(
        [person('Ana', DateTime(1990, 8, 19))],
        now: DateTime(2026, 8, 19, 15),
      );

      expect(nudges, isEmpty);
    });

    test('a birthday months away is left alone for now', () {
      // Scheduling a hundred alarms a year ahead is how an OS starts dropping
      // them. They get scheduled as the date comes into range.
      expect(
        birthdayNudges([person('Luis', DateTime(1985, 12, 25))], now: now),
        isEmpty,
      );
    });

    test('someone with no birth date is skipped, not guessed', () {
      expect(birthdayNudges(const [], now: now), isEmpty);
    });
  });

  group('what it says', () {
    test('the day-of names the person and the age', () {
      final nudges = birthdayNudges(
        [person('Sofía', DateTime(2019, 8, 19))],
        now: DateTime(2026, 8, 19, 6),
      );

      final text = nudges.first.message;
      expect(text, contains('Sofía'));
      expect(text, contains('7'));
    });

    test('the early one says how many days are left', () {
      final nudges = birthdayNudges(
        [person('Sofía', DateTime(2019, 8, 24))],
        now: now,
      );
      final ahead = nudges.firstWhere((n) => n.kind == BirthdayNudgeKind.ahead);

      expect(ahead.message, contains('Sofía'));
      expect(ahead.message, contains('5'));
    });

    test('a known relation is used, because it gives you something to say', () {
      // "Sofía, hija de Juan, cumple 7" is a reason to write to Juan.
      final nudges = birthdayNudges(
        [person('Sofía', DateTime(2019, 8, 19), relation: 'hija de Juan')],
        now: DateTime(2026, 8, 19, 6),
      );

      expect(nudges.first.message, contains('Juan'));
    });
  });

  group('ids', () {
    test('the same birthday always gets the same notification id', () {
      // Re-scheduling on every launch must REPLACE the alarm, not stack a new
      // one beside it — otherwise a phone left on for a week fires seven.
      final first = birthdayNudges([person('Ana', DateTime(1990, 8, 24))], now: now);
      final again = birthdayNudges([person('Ana', DateTime(1990, 8, 24))], now: now);

      expect(first.map((n) => n.id), again.map((n) => n.id));
    });

    test('two people never collide', () {
      final nudges = birthdayNudges([
        person('Ana', DateTime(1990, 8, 24)),
        person('Luis', DateTime(1990, 8, 24)),
      ], now: now);

      final ids = nudges.map((n) => n.id).toSet();
      expect(ids.length, nudges.length);
    });

    test('the two kinds for one person do not collide either', () {
      final nudges = birthdayNudges([person('Ana', DateTime(1990, 8, 24))], now: now);

      expect(nudges.map((n) => n.id).toSet().length, nudges.length);
    });
  });
}
