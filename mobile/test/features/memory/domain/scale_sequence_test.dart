// Proves the BARE SCALE DICTATION: the user reads out only the numbers their
// smart scale cycles through, with no labels, and each one is assigned to the
// right metric by its plausible range — whatever position the dictation starts
// from.
//
// Reported: "15.5, 7, 36.9, 1395, 23.4, 59.8" was not captured at all. The
// laptop has had this parser for months (`_try_bare_scale_sequence`); the Dart
// port carried it as a deferred TODO, so voice messages from the phone — where
// the user actually dictates — fell through to a raw fact or nothing.
//
// PRECISION-FIRST: this must never guess. Exactly one rotation of the cycle may
// fit; on zero or two the parser yields and the labeled path keeps ownership.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/scale_sequence_parser.dart';

void main() {
  group('the reported dictation', () {
    test('assigns all six metrics, starting mid-cycle at body fat', () {
      final r = parseScaleSequence('15.5, 7, 36.9, 1395, 23.4, 59.8');

      expect(r, isNotNull);
      expect(r!.fields, {
        'body_fat_pct': 15.5,
        'visceral_fat': 7.0,
        'muscle_pct': 36.9,
        'basal_metabolic_rate': 1395.0,
        'bmi': 23.4,
        'weight_kg': 59.8,
      });
      // The title lets the user audit the assignment in the capture ack —
      // silently guessing at health data would be worse than not capturing.
      expect(r.title, contains('grasa 15.5%'));
      expect(r.title, contains('peso 59.8'));
    });

    test('the same numbers work from the start of the cycle', () {
      final r = parseScaleSequence('59.8 15.5 7 36.9 1395 23.4');

      expect(r!.fields['weight_kg'], 59.8);
      expect(r.fields['bmi'], 23.4);
    });

    test('separators and unit words do not matter', () {
      for (final text in [
        '59.8 kg, 15.5%, 7, 36.9%, 1395 kcal, 23.4',
        '59,8 15,5 7 36,9 1395 23,4',
        '59.8 y 15.5 y 7 y 36.9 y 1395 y 23.4',
      ]) {
        expect(parseScaleSequence(text)?.fields['weight_kg'], 59.8,
            reason: text);
      }
    });
  });

  group('refusal — never guess at health data', () {
    test('a sentence with real words is left to the labeled parsers', () {
      expect(parseScaleSequence('peso 59.8 y grasa 15.5'), isNull);
      expect(parseScaleSequence('me dormi 12:30 y me desperte a las 6:30'),
          isNull);
    });

    test('three bare numbers stay with blood pressure', () {
      // "112 82 50" is a BP reading, not a scale cycle.
      expect(parseScaleSequence('112 82 50'), isNull);
    });

    test('more than seven numbers is not a scale reading', () {
      expect(parseScaleSequence('1 2 3 4 5 6 7 8'), isNull);
    });

    test('values outside their physiological range yield nothing', () {
      // 900 fits no slot in any rotation.
      expect(parseScaleSequence('900 15.5 7 36.9 1395 23.4'), isNull);
    });

    test('a non-integer visceral fat is refused', () {
      // The slot is integer-valued; 7.5 means the rotation is wrong.
      expect(parseScaleSequence('15.5 7.5 36.9 1395 23.4 59.8'), isNull);
    });

    test('an ambiguous run — two rotations fit — is refused', () {
      // Four mid-range values that several slots accept: assigning them would
      // be a coin flip written into the user's health record.
      final r = parseScaleSequence('23.4 23.4 23.4 23.4');
      expect(r, isNull);
    });
  });

  group('partial cycles', () {
    test('four numbers starting at visceral are enough', () {
      final r = parseScaleSequence('7 36.9 1395 23.4');

      expect(r, isNotNull);
      expect(r!.fields, {
        'visceral_fat': 7.0,
        'muscle_pct': 36.9,
        'basal_metabolic_rate': 1395.0,
        'bmi': 23.4,
      });
    });

    test('a run that wraps onto a repeated slot is refused', () {
      // Seven numbers over a six-slot cycle must repeat one — never guess.
      expect(parseScaleSequence('59.8 15.5 7 36.9 1395 23.4 59.8'), isNull);
    });
  });

  group('configurable cycle', () {
    test('a different scale order is honoured', () {
      // Some scales report BMI first. The order is data, not code.
      final r = parseScaleSequence(
        '23.4 59.8 15.5 7 36.9 1395',
        sequence: const ['bmi', 'weight', 'fat', 'visceral', 'muscle', 'bmr'],
      );

      expect(r!.fields['bmi'], 23.4);
      expect(r.fields['weight_kg'], 59.8);
    });
  });
}
