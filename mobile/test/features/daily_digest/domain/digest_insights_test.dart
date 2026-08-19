// The daily summary should tell you something you did not already know.
//
// Today it is an inventory: "Salud: 2 registros · Yo: peso 82 kg (09:16)".
// Correct, and it says nothing a person could not get by opening the list —
// so there is no reason to read it, and a summary nobody reads is a
// notification people turn off.
//
// The vision behind LifeOS is the opposite: "al final todo es estadística".
// This is the first honest step toward it — patterns ACROSS days, computed
// from what is actually stored:
//
//   * a streak ("tercer día seguido con ejercicio") — the thing that makes
//     someone not want to break it;
//   * a gap ("no registras presión desde hace 8 días") — the thing they meant
//     to keep up and quietly stopped;
//   * a comparison with yesterday.
//
// NOTHING IS INFERRED beyond counting. No "you seem stressed", no advice, no
// correlation claimed between domains from a handful of points. The moment
// this starts interpreting, it starts being wrong about someone's health, and
// that is a line this app does not cross for a nicer sentence.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/daily_digest/domain/digest_insights.dart';

void main() {
  final today = DateTime(2026, 8, 19);

  DigestDay day(int daysAgo, Map<String, int> counts) => DigestDay(
        date: today.subtract(Duration(days: daysAgo)),
        countsByDomain: counts,
      );

  group('streaks', () {
    test('three days in a row is called out', () {
      final lines = digestInsights([
        day(0, {'exercise': 1}),
        day(1, {'exercise': 1}),
        day(2, {'exercise': 1}),
      ], today: today);

      expect(lines.join(' '), contains('3'));
      expect(lines.join(' ').toLowerCase(), contains('seguido'));
    });

    test('a single day is not a streak', () {
      // "Llevas 1 día seguido" is noise dressed as an achievement.
      final lines = digestInsights([day(0, {'exercise': 1})], today: today);

      expect(lines.join(' ').toLowerCase(), isNot(contains('seguido')));
    });

    test('a broken chain does not count the days before the break', () {
      final lines = digestInsights([
        day(0, {'exercise': 1}),
        day(1, {'exercise': 1}),
        day(3, {'exercise': 1}),
        day(4, {'exercise': 1}),
      ], today: today);

      expect(lines.join(' '), isNot(contains('4 días')));
    });
  });

  group('gaps', () {
    test('something logged regularly and then dropped is surfaced', () {
      final lines = digestInsights([
        for (var i = 10; i < 20; i++) day(i, {'health': 1}),
        day(0, {'exercise': 1}),
      ], today: today);

      expect(lines.join(' ').toLowerCase(), contains('salud'));
      expect(lines.join(' '), contains('10'));
    });

    test('something never logged is not reported as missing', () {
      // "No registras finanzas desde hace nunca" — a habit the user never had
      // is not a lapse, and nagging about it is how an app becomes a chore.
      final lines = digestInsights([day(0, {'exercise': 1})], today: today);

      expect(lines.join(' ').toLowerCase(), isNot(contains('finanzas')));
    });

    test('a short gap is not worth mentioning', () {
      final lines = digestInsights([
        day(0, {'exercise': 1}),
        day(2, {'health': 1}),
      ], today: today);

      expect(lines.join(' ').toLowerCase(), isNot(contains('no registras salud')));
    });
  });

  group('what it refuses to say', () {
    test('it never gives health advice', () {
      final lines = digestInsights([
        for (var i = 0; i < 5; i++) day(i, {'health': 3}),
      ], today: today);

      final text = lines.join(' ').toLowerCase();
      for (final forbidden in ['deberías', 'te recomiendo', 'consulta', 'toma']) {
        expect(text, isNot(contains(forbidden)));
      }
    });

    test('an empty history says nothing at all', () {
      // Not "no tienes datos suficientes" — that is a sentence about the app,
      // not about the person's day.
      expect(digestInsights(const [], today: today), isEmpty);
    });

    test('a single day of history produces no cross-day claims', () {
      expect(digestInsights([day(0, {'health': 2})], today: today), isEmpty);
    });
  });

  group('folding real timestamps into days', () {
    test('entries on the same day count together', () {
      final days = digestDaysFrom(
        {
          'health': [
            DateTime(2026, 8, 19, 9),
            DateTime(2026, 8, 19, 21),
            DateTime(2026, 8, 18, 9),
          ],
        },
        today: today,
      );

      expect(days.first.countsByDomain['health'], 2);
      expect(days.length, 2);
    });

    test('anything older than the window is dropped', () {
      // Otherwise a two-year history would be walked on every summary.
      final days = digestDaysFrom(
        {'health': [DateTime(2020, 1, 1)]},
        today: today,
      );

      expect(days, isEmpty);
    });

    test('a future timestamp does not become "today"', () {
      // A scheduled appointment is not something you logged today.
      final days = digestDaysFrom(
        {'calendar': [DateTime(2026, 9, 1)]},
        today: today,
      );

      expect(days, isEmpty);
    });

    test('newest first, so the streak walk starts at today', () {
      final days = digestDaysFrom(
        {
          'exercise': [
            DateTime(2026, 8, 17),
            DateTime(2026, 8, 19),
            DateTime(2026, 8, 18),
          ],
        },
        today: today,
      );

      expect(days.first.date.day, 19);
      expect(days.last.date.day, 17);
    });
  });
}

