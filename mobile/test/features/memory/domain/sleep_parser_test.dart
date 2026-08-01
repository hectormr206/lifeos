// Proves the DETERMINISTIC natural-language sleep CLOCK-MATH: a spoken bedtime →
// wake time becomes a real `sleep_hours` duration, computed in Dart with an
// INJECTED clock (ADR-4: a small model must never do time arithmetic).
//
// Vectors ported from the laptop `lifeos/tests/test_health_ingestion.py`
// (test_natural_sleep_*, test_sleep_*) so both brains agree on the same math.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/health_parser.dart';
import 'package:lifeos/features/memory/domain/sleep_parser.dart';

void main() {
  // Fixed "now" so every implicit-wake case is deterministic (07:30 local).
  final now = DateTime(2026, 7, 24, 7, 30);

  group('THE reported bug: bedtime + implicit "acabo de despertar"', () {
    test('"me dormi a las 12 am y acabo de despertar" → 7.5h with the range',
        () {
      final p = parseHealthEntry(
        'me dormi a las 12 am y acabo de despertar',
        now: now,
      );
      expect(p, isNotNull);
      expect(p!.type, 'sleep_hours');
      expect(p.fields, {'hours': 7.5});
      // AUDITABLE title — this is what the capture ack shows the user.
      expect(p.title, 'dormí 7.5h (00:00–07:30)');
      expect(p.subject, isNull);
    });

    test('"...desperté ahorita" resolves the wake time to now', () {
      final w = parseSleepWindow('me dormí a la una y media y desperté ahorita',
          now: now);
      expect(w!.hours, 6.0);
      expect(w.startHour24, 1);
      expect(w.startMinute, 30);
      expect(w.range, '01:30–07:30');
    });

    test('"ya me levanté" (bare "ya") also means now', () {
      final w = parseSleepWindow('me acosté a las 11 y ya me levanté', now: now);
      expect(w!.hours, 8.5);
      expect(w.startHour24, 23);
    });

    test('a bare wake verb with no time qualifier means now', () {
      final w = parseSleepWindow('me dormí a las 11 pm y acabo de levantarme',
          now: now);
      expect(w!.hours, 8.5);
    });

    test('no clock injected → no guess, no entry (parser stays pure)', () {
      expect(parseSleepWindow('me dormi a las 12 am y acabo de despertar'),
          isNull);
      expect(parseHealthEntry('me dormi a las 12 am y acabo de despertar'),
          isNull);
    });
  });

  group('midnight crossing', () {
    test('THE laptop golden: 23:50 → 05:50 is 6.0h (not 8h, not -18h)', () {
      final p = parseHealthEntry(
        'me dormí a las 11:50 pm y desperté a las 5:50 am',
        now: now,
      );
      expect(p!.type, 'sleep_hours');
      expect(p.fields, {'hours': 6.0});
      expect(p.title, 'dormí 6h (23:50–05:50)');
    });

    test('"me dormí a las 23 y desperté a las 7" (24h notation) → 8.0h', () {
      final w = parseSleepWindow('me dormí a las 23 y desperté a las 7');
      expect(w!.hours, 8.0);
      expect(w.startHour24, 23);
      expect(w.endHour24, 7);
    });

    test('12 am bedtime + same-day wake needs no rollover', () {
      final w = parseSleepWindow('me dormí a las 12 am y desperté a las 6 am');
      expect(w!.hours, 6.0);
      expect(w.startHour24, 0);
    });
  });

  group('"dormí de X a Y"', () {
    test('"dormí de 11 a 7" → 8.0h', () {
      final p = parseHealthEntry('dormí de 11 a 7');
      expect(p!.fields, {'hours': 8.0});
      expect(p.title, 'dormí 8h (23:00–07:00)');
    });

    test('"dormí de 11 pm hasta 6:30 am" → 7.5h', () {
      final w = parseSleepWindow('dormí de 11 pm hasta 6:30 am');
      expect(w!.hours, 7.5);
      expect(w.endMinute, 30);
    });

    test('EN: "slept from 11 to 7" → 8.0h', () {
      expect(parseSleepWindow('slept from 11 to 7')!.hours, 8.0);
    });
  });

  group('word-form hours, spoken periods and minutes', () {
    test('"a la una de la madrugada" + ahorita (laptop vector, 01:00 → now)',
        () {
      final w = parseSleepWindow(
        'Me dormí a la una de la madrugada y acabo de despertar ahorita.',
        now: DateTime(2026, 5, 25, 8, 0),
      );
      expect(w!.startHour24, 1);
      expect(w.hours, 7.0);
    });

    test('"11 de la noche" → 23:00, "7 de la mañana" → 07:00 = 8.0h', () {
      final w = parseSleepWindow(
        'Me dormí a las 11 de la noche y desperté a las 7 de la mañana.',
      );
      expect(w!.startHour24, 23);
      expect(w.endHour24, 7);
      expect(w.hours, 8.0);
    });

    test('"8 y media" = 08:30 → 5.5h, not 5.0h', () {
      final w = parseSleepWindow(
        'Me dormí a las 3 de la mañana y desperté a las 8 y media de la mañana.',
      );
      expect(w!.hours, 5.5);
      expect(w.endHour24, 8);
      expect(w.endMinute, 30);
    });

    test('"11 y cuarto de la noche" = 23:15', () {
      final w =
          parseSleepWindow('Me dormí a las 11 y cuarto de la noche y desperté a las 7');
      expect(w!.startMinute, 15);
      expect(w.startHour24, 23);
    });

    test('"6 de la noche" is 18:00 (PM), not 06:00', () {
      final w = parseSleepWindow(
        'me dormí a las 6 de la noche y me levanté a las 2 de la madrugada',
      );
      expect(w!.startHour24, 18);
      expect(w.hours, 8.0);
    });

    test('"3 de la noche" stays AM (madrugada convention)', () {
      final w =
          parseSleepWindow('me dormí a las 3 de la noche y me levanté a las 7');
      expect(w!.startHour24, 3);
      expect(w.hours, 4.0);
    });

    test('"12 de la mañana" is noon, not midnight', () {
      expect(
        parseSleepWindow('dormí de 2 de la mañana a 12 de la mañana')!.endHour24,
        12,
      );
      expect(
        parseSleepWindow(
          'me dormí a las 2 de la mañana y me levanté a las 12 de la mañana',
        )!.endHour24,
        12,
      );
    });

    test('"4 de la noche" is 16:00 and "12 de la noche" is midnight', () {
      final w = parseSleepWindow('dormí de 4 de la noche a 12 de la noche');
      expect(w!.startHour24, 16);
      expect(w.endHour24, 0);
      expect(w.hours, 8.0);
    });

    test('"me fui a dormir a las 11 y desperté a las 7" → 8.0h', () {
      expect(parseSleepWindow('me fui a dormir a las 11 y desperté a las 7')!.hours,
          8.0);
    });

    test('"me acosté a las 11 y me levanté a las 7" → 8.0h', () {
      expect(parseSleepWindow('me acosté a las 11 y me levanté a las 7')!.hours,
          8.0);
    });
  });

  group('RANGE GATE 0.5-16h — better no entry than wrong data', () {
    test('a 10-minute delta emits NOTHING', () {
      expect(
        parseSleepWindow('me dormí a las 7 am y desperté a las 7:10 am'),
        isNull,
      );
      expect(
        parseHealthEntry('me dormí a las 7 am y desperté a las 7:10 am'),
        isNull,
      );
    });

    test('17h (13:00 → 06:00) emits NOTHING (laptop plausibility vector)', () {
      final p = parseHealthEntry(
        'me acosté a la 1 de la tarde y me levanté a las 6 de la mañana',
        now: now,
      );
      expect(p == null || p.type != 'sleep_hours', isTrue);
    });

    test('an out-of-range "dormí de X a Y" does not emit a bogus entry', () {
      expect(parseSleepWindow('dormí de 8 am a 8:15 am'), isNull);
    });
  });

  group('precedence and regressions', () {
    test('the clock-math shape WINS over the explicit "dormí N horas" shape',
        () {
      // Both shapes match; the computed 8h must beat the stated 5h.
      final p = parseHealthEntry(
        'me dormí a las 11 y desperté a las 7, dormí 5 horas',
        now: now,
      );
      expect(p!.fields, {'hours': 8.0});
      expect(p.title, 'dormí 8h (23:00–07:00)');
    });

    test('the explicit shape still works untouched', () {
      final p = parseHealthEntry('dormí 8 horas');
      expect(p!.type, 'sleep_hours');
      expect(p.fields, {'hours': 8.0});
      expect(p.title, 'dormí 8h');
    });

    test('"dormí 6 horas y media" still parses as 6.5', () {
      expect(parseHealthEntry('anoche dormí 6 horas y media')!.fields,
          {'hours': 6.5});
    });

    test('a non-sleep line is untouched by the new parser', () {
      expect(parseSleepWindow('presión 120/80, pulso 60', now: now), isNull);
      expect(parseHealthEntry('presión 120/80', now: now)!.type,
          'blood_pressure');
    });

    test('subject routing: the wife\'s sleep attributes to esposa', () {
      final p = parseHealthEntry(
        'mi esposa se durmió a las 11 y despertó a las 7',
        now: now,
      );
      expect(p!.type, 'sleep_hours');
      expect(p.fields, {'hours': 8.0});
      expect(p.subject, 'esposa');
    });
  });

  group('sleepPhraseSpans (the segmenter guard)', () {
    test('the span covers the " y " that would split the phrase', () {
      const text = 'me dormi a las 12 am y acabo de despertar';
      final spans = sleepPhraseSpans(text);
      expect(spans, isNotEmpty);
      final conjunction = text.indexOf(' y ');
      expect(
        spans.any((s) => conjunction > s.start && conjunction < s.end),
        isTrue,
      );
    });

    test('a line with no sleep phrase has no protected span', () {
      expect(sleepPhraseSpans('122 77 55 pulsos, corrí 5km'), isEmpty);
    });
  });

  // Reported from the phone: "me dormi 12:30 y me desperte a las 06:30" was not
  // captured at all. The onset heuristic resolved a BARE 12 to NOON — every
  // other branch in _resolveHour24 maps 12 to midnight — so the window became
  // 12:00→06:30, an 18.5 h duration that the 16 h gate then rejected. The user
  // saw nothing stored and no reason why.
  group('midnight bedtime stated as a bare 12', () {
    test('the reported utterance computes six hours', () {
      final w = parseSleepWindow(
        'me dormi 12:30 y me desperte a las 06:30',
        now: now,
      );

      expect(w, isNotNull);
      expect(w!.hours, 6.0);
      expect(w.range, '00:30–06:30');
    });

    test('a bare 12 onset is midnight, like every other branch resolves it',
        () {
      expect(parseSleepWindow('me acoste a las 12 y me levante a las 6',
              now: now)!.hours,
          6.0);
      // Consistent with the neighbouring hour, which already assumed night.
      expect(parseSleepWindow('me acoste a las 11 y me levante a las 6',
              now: now)!.hours,
          7.0);
    });

    test('an explicit "12 am" still means midnight', () {
      expect(parseSleepWindow('me dormi a las 12 am y me desperte a las 6',
              now: now)!.hours,
          6.0);
    });

    test('"12 de la mañana" still means noon, and is refused as a bedtime', () {
      // Noon→06:30 is 18.5 h, outside the 0.5-16 gate: nothing is stored,
      // which is the correct outcome for a genuinely odd claim.
      expect(
        parseSleepWindow(
            'me dormi a las 12 de la manana y me desperte a las 6:30',
            now: now),
        isNull,
      );
    });
  });

  // THE SECOND REPORTED BUG, and the more damaging one.
  //
  // "Ayer me dormí como a la 11 y media y me desperté 7 y media" was stored as
  // 23:30–08:25 — 08:25 being the moment the message was SENT, not the moment
  // the user woke. The stated wake time was dropped on the floor.
  //
  // Cause: the end-time branch required the preposition ("desperté A LAS 7").
  // Without it the group never matched, the parser fell through to its
  // implicit-now path, and silently invented a wake time. Every one of the 35
  // tests above happened to use "a las", so the whole suite was blind to it.
  //
  // The failure mode is the worst kind: it does not error, it does not refuse —
  // it writes a WRONG number and reports success. A user who says a time and is
  // told a different one back has no reason to trust the next answer either.
  group('a wake time stated WITHOUT the preposition', () {
    // 08:25 is deliberately far from every expected result, so any test that
    // silently falls back to "now" fails loudly instead of looking plausible.
    final sent = DateTime(2026, 7, 31, 8, 25);

    test('the exact reported sentence → 8.0h, NOT 8.92h to the send time', () {
      final w = parseSleepWindow(
        'Ayer me dormí como a la 11 y media y me desperté 7 y media',
        now: sent,
      );

      expect(w, isNotNull);
      expect(w!.hours, 8.0);
      expect(w.range, '23:30–07:30');
    });

    test('the message time NEVER leaks in when a wake time was stated', () {
      // The precise regression: the wake minute must come from the sentence.
      final w = parseSleepWindow(
        'Ayer me dormí como a la 11 y media y me desperté 7 y media',
        now: sent,
      );

      expect(w!.endHour24, 7);
      expect(w.endMinute, 30);
    });

    // The user's own words: "puedo decirle muchas formas de a qué hora me dormí
    // y a qué hora desperté". These are those forms.
    final forms = <String, double>{
      // Bare wake hour, no preposition.
      'me dormí a las 11 y media y me desperté 7 y media': 8.0,
      'me dormí 11 y media y desperté 7 y media': 8.0,
      'me acosté 11:30 y me levanté 7:30': 8.0,
      'me dormí a las 11 y desperté 7': 8.0,
      // Colloquial approximations on either side.
      'me dormí como a las 11 y me desperté como 7': 8.0,
      'me dormí tipo 11 y me desperté tipo 7': 8.0,
      'me dormí a eso de las 11 y me desperté a eso de las 7': 8.0,
      // Word-form hours.
      'me dormí a las once y media y me desperté siete y media': 8.0,
      'me acosté once y me levanté siete': 8.0,
      // 24-hour notation with no preposition.
      'me dormí 23:30 y me desperté 07:30': 8.0,
      // Day-period words still win over the bare-hour heuristic.
      'me dormí 11 de la noche y me desperté 7 de la mañana': 8.0,
      // The "de X a Y" shape with approximations.
      'dormí de 11 y media a 7 y media': 8.0,
    };

    forms.forEach((sentence, expected) {
      test('"$sentence" → ${expected}h', () {
        final w = parseSleepWindow(sentence, now: sent);
        expect(w, isNotNull, reason: 'no window parsed');
        expect(w!.hours, expected);
        // Whatever it parsed, it must NOT be the send time.
        expect(w.endMinute, isNot(25),
            reason: 'wake minute came from the clock, not the sentence');
      });
    });

    test('a BARE wake verb still means now — that shape is not regressed', () {
      // "acabo de despertar" genuinely has no stated time; falling back to the
      // injected clock is correct there and must keep working.
      final w = parseSleepWindow(
        'me dormí a las 11 y media y acabo de despertar',
        now: DateTime(2026, 7, 31, 7, 30),
      );

      expect(w!.hours, 8.0);
      expect(w.endMinute, 30);
    });

    test('a number that is not a time is not mistaken for one', () {
      // Precision guard: making the preposition optional must not let any digit
      // after the wake verb become a wake hour.
      final w = parseSleepWindow(
        'me dormí a las 11 y media y desperté con 3 llamadas perdidas',
        now: DateTime(2026, 7, 31, 7, 30),
      );

      // Falls back to the injected clock (07:30), never to "3 o'clock".
      expect(w!.endHour24, 7);
      expect(w.endMinute, 30);
    });
  });
}
