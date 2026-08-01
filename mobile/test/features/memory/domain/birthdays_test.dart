// Proves the on-device birthday computation: who has one coming up, what age
// they turn, and the two cases that quietly lose real birthdays if unhandled —
// a window that crosses New Year, and 29 February in a common year.
//
// Ports the laptop `lifeos/src/lifeos/relationships/people.py` logic so both
// brains agree on the same dates. Pure and clock-injected: nothing here reads
// DateTime.now, so the tests pin the day.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/birthdays.dart';

PersonBirthday _p(String name, DateTime born, {String? relation}) =>
    PersonBirthday(name: name, birthDate: born, relation: relation);

void main() {
  group('upcoming', () {
    test('finds a birthday inside the window and the age it turns', () {
      final list = upcomingBirthdays(
        [_p('Juan', DateTime(1988, 3, 20))],
        today: DateTime(2026, 3, 1),
        withinDays: 30,
      );

      expect(list, hasLength(1));
      expect(list.first.person.name, 'Juan');
      expect(list.first.on, DateTime(2026, 3, 20));
      expect(list.first.turning, 38);
      expect(list.first.daysAway, 19);
    });

    test('a birthday today is included, not skipped', () {
      final list = upcomingBirthdays(
        [_p('Hoy', DateTime(1990, 3, 1))],
        today: DateTime(2026, 3, 1),
        withinDays: 7,
      );

      expect(list.first.daysAway, 0);
      expect(list.first.turning, 36);
    });

    test('one outside the window is left out', () {
      expect(
        upcomingBirthdays(
          [_p('Lejos', DateTime(1990, 9, 1))],
          today: DateTime(2026, 3, 1),
          withinDays: 30,
        ),
        isEmpty,
      );
    });

    test('soonest first', () {
      final list = upcomingBirthdays(
        [
          _p('Lejano', DateTime(1990, 3, 28)),
          _p('Cercano', DateTime(1990, 3, 5)),
        ],
        today: DateTime(2026, 3, 1),
        withinDays: 60,
      );

      expect(list.map((b) => b.person.name), ['Cercano', 'Lejano']);
    });
  });

  group('the cases that silently lose a birthday', () {
    test('a window crossing New Year still finds it', () {
      // Naively comparing month/day against "this year" drops every birthday
      // in the first days of January for the whole of late December.
      final list = upcomingBirthdays(
        [_p('Ana', DateTime(1990, 1, 5))],
        today: DateTime(2025, 12, 28),
        withinDays: 20,
      );

      expect(list.first.on, DateTime(2026, 1, 5));
      expect(list.first.turning, 36);
      expect(list.first.daysAway, 8);
    });

    test('29 February lands on the 28th in a common year', () {
      // Dropping it would hide a real birthday three years out of four.
      final list = upcomingBirthdays(
        [_p('Bisiesto', DateTime(2000, 2, 29))],
        today: DateTime(2026, 2, 1),
        withinDays: 40,
      );

      expect(list.first.on, DateTime(2026, 2, 28));
      expect(list.first.turning, 26);
    });

    test('29 February stays on the 29th in a leap year', () {
      final list = upcomingBirthdays(
        [_p('Bisiesto', DateTime(2000, 2, 29))],
        today: DateTime(2028, 2, 1),
        withinDays: 40,
      );

      expect(list.first.on, DateTime(2028, 2, 29));
    });
  });

  group('age', () {
    test('is computed, never stored — the day before and the day of', () {
      final born = DateTime(1988, 3, 15);

      expect(ageOn(born, DateTime(2026, 3, 14)), 37);
      expect(ageOn(born, DateTime(2026, 3, 15)), 38);
    });

    test('a child is not rounded away', () {
      expect(ageOn(DateTime(2019, 3, 10), DateTime(2026, 3, 10)), 7);
    });
  });

  group('what the nudge says', () {
    test('carries the relation so the reminder has something to say', () {
      // "Juan's daughter Sofía turns 7 next week" is useful. "You have not
      // spoken to Juan in 45 days" is administrative guilt.
      final list = upcomingBirthdays(
        [_p('Sofía', DateTime(2019, 3, 10), relation: 'hija de Juan')],
        today: DateTime(2026, 3, 1),
        withinDays: 30,
      );

      expect(list.first.person.relation, 'hija de Juan');
      expect(list.first.describe(), 'Sofía (hija de Juan) cumple 7 el 10 de marzo');
    });

    test('describes someone with no stated relation plainly', () {
      final list = upcomingBirthdays(
        [_p('Juan', DateTime(1988, 3, 20))],
        today: DateTime(2026, 3, 1),
        withinDays: 30,
      );

      expect(list.first.describe(), 'Juan cumple 38 el 20 de marzo');
    });
  });
}
