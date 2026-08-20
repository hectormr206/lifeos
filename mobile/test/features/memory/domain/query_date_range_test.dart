// Understanding WHEN the question is about.
//
// "¿Qué anoté el martes?" used to search by words, so it found whatever
// happened to mention "martes" and missed everything actually recorded that
// day. The memory knew the date of every entry and had no way to be asked
// about it.
//
// This reads the time expression out of the question, in Dart. Two rules run
// through every case below:
//
//   * A range is only returned when the question REALLY names a time. "¿cómo
//     voy de peso?" has no date in it, and inventing one would silently hide
//     everything outside a window the user never asked for — the worst kind of
//     bug, because the answer looks complete.
//   * Days are whole days in local time, from 00:00 to 23:59, or a fact
//     logged at 09:16 falls outside "yesterday".
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/query_date_range.dart';

void main() {
  // Wednesday 19 August 2026, 18:00.
  final now = DateTime(2026, 8, 19, 18);

  group('the plain ones', () {
    test('hoy', () {
      final range = parseQueryDateRange('¿qué anoté hoy?', now: now)!;

      expect(range.from, DateTime(2026, 8, 19));
      expect(range.to.day, 19);
      expect(range.to.hour, 23);
    });

    test('ayer', () {
      final range = parseQueryDateRange('¿cuánto pesé ayer?', now: now)!;

      expect(range.from, DateTime(2026, 8, 18));
      expect(range.to.day, 18);
    });

    test('anteayer', () {
      final range = parseQueryDateRange('qué hice anteayer', now: now)!;

      expect(range.from.day, 17);
    });
  });

  group('weekdays name the LAST one, not the next', () {
    test('el martes, from a Wednesday, is yesterday', () {
      final range = parseQueryDateRange('¿qué anoté el martes?', now: now)!;

      expect(range.from, DateTime(2026, 8, 18));
    });

    test('el viernes, from a Wednesday, is five days back', () {
      // Asking on Wednesday about "el viernes" means the one that happened,
      // because you cannot have recorded anything on a Friday still to come.
      final range = parseQueryDateRange('qué pasó el viernes', now: now)!;

      expect(range.from, DateTime(2026, 8, 14));
    });

    test('naming today\'s own weekday means today', () {
      final range = parseQueryDateRange('qué anoté el miércoles', now: now)!;

      expect(range.from, DateTime(2026, 8, 19));
    });
  });

  group('spans', () {
    test('esta semana starts on Monday', () {
      final range = parseQueryDateRange('cómo voy esta semana', now: now)!;

      expect(range.from, DateTime(2026, 8, 17));
      expect(range.to.day, 19);
    });

    test('la semana pasada is the previous Monday to Sunday', () {
      final range = parseQueryDateRange('qué hice la semana pasada', now: now)!;

      expect(range.from, DateTime(2026, 8, 10));
      expect(range.to.day, 16);
    });

    test('este mes', () {
      final range = parseQueryDateRange('mis gastos de este mes', now: now)!;

      expect(range.from, DateTime(2026, 8, 1));
    });

    test('el mes pasado', () {
      final range = parseQueryDateRange('cuánto gasté el mes pasado', now: now)!;

      expect(range.from, DateTime(2026, 7, 1));
      expect(range.to.month, 7);
      expect(range.to.day, 31);
    });

    test('hace tres días', () {
      final range = parseQueryDateRange('qué anoté hace tres días', now: now)!;

      expect(range.from, DateTime(2026, 8, 16));
    });

    test('hace 3 días, in digits', () {
      expect(parseQueryDateRange('hace 3 días', now: now)!.from,
          DateTime(2026, 8, 16));
    });
  });

  group('it does not invent a date', () {
    // The rule that keeps answers honest: with no time expression there is no
    // window, and the recall behaves exactly as it does today.
    for (final question in const [
      '¿cómo voy de peso?',
      '¿quién es Laura?',
      'cuéntame un chiste',
      'qué tal',
      '',
    ]) {
      test('"$question" no acota nada', () {
        expect(parseQueryDateRange(question, now: now), isNull);
      });
    }

    test('a month named inside a word is not a date', () {
      // "mayoría" contains "mayo".
      expect(parseQueryDateRange('la mayoría de los días', now: now), isNull);
    });
  });

  group('filtering by the range', () {
    test('only what falls inside comes through', () {
      final range = parseQueryDateRange('ayer', now: now)!;

      expect(range.contains(DateTime(2026, 8, 18, 9, 16)), isTrue);
      expect(range.contains(DateTime(2026, 8, 19, 9, 16)), isFalse);
      expect(range.contains(DateTime(2026, 8, 17, 23, 59)), isFalse);
    });

    test('the edges of the day are inside', () {
      final range = parseQueryDateRange('ayer', now: now)!;

      expect(range.contains(DateTime(2026, 8, 18, 0, 0)), isTrue);
      expect(range.contains(DateTime(2026, 8, 18, 23, 59, 59)), isTrue);
    });
  });
}
