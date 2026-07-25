// Proves the DETERMINISTIC multi-topic / multi-person segmenter:
//   * clause splitting on commas + connectors, WITHOUT cutting numeric
//     measurement sequences ("120, 60, 49 pulsos" stays whole);
//   * a family-subject marker is LOCAL to its clause and PROPAGATES FORWARD,
//     never BACKWARD — a trailing "de mi esposa" never retags earlier clauses;
//   * a clause with no preceding marker defaults to the USER (subject == null);
//   * multiple subjects in one line route independently;
//   * empty / garbage input never crashes.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/utterance_segmenter.dart';

void main() {
  const seg = UtteranceSegmenter();

  group('subject attribution is LOCAL / positional', () {
    test('the crown-jewel mixed utterance splits into 4 attributed clauses', () {
      final out = seg.segment(
        '122 77 55 pulsos, corrí 5km en la mañana, recé el rosario, '
        'y de mi esposa son 120 60 49 pulsos',
      );

      expect(out.length, 4);

      // My readings/notes have NO subject (default = me)…
      expect(out[0].text, '122 77 55 pulsos');
      expect(out[0].subject, isNull);
      expect(out[1].text, 'corrí 5km en la mañana');
      expect(out[1].subject, isNull);
      expect(out[2].text, 'recé el rosario');
      expect(out[2].subject, isNull);

      // …only the LAST clause carries the esposa marker (stripped from text).
      expect(out[3].subject, 'esposa');
      expect(out[3].text, contains('120 60 49 pulsos'));
      expect(out[3].text, isNot(contains('esposa')));
    });

    test('a TRAILING marker does NOT retag earlier clauses', () {
      final out = seg.segment('122 77 55 pulsos, de mi esposa 120 80 60 pulsos');
      expect(out.length, 2);
      expect(out[0].subject, isNull, reason: 'the first reading stays mine');
      expect(out[0].text, '122 77 55 pulsos');
      expect(out[1].subject, 'esposa');
    });

    test('a no-marker single clause defaults to the user (null subject)', () {
      final out = seg.segment('122 77 55 pulsos');
      expect(out.single.subject, isNull);
      expect(out.single.text, '122 77 55 pulsos');
    });

    test('a marker PROPAGATES FORWARD until the next marker', () {
      final out = seg.segment(
        'de mi papá 130 85 70 pulsos, glucosa 190, y de mi esposa 120 80 60 pulsos',
      );
      expect(out.length, 3);
      expect(out[0].subject, 'papá');
      // No marker on the glucose clause → inherits the running subject (papá).
      expect(out[1].subject, 'papá');
      expect(out[1].text, 'glucosa 190');
      // A new marker re-anchors to esposa.
      expect(out[2].subject, 'esposa');
    });

    test('multiple subjects in one line route independently', () {
      final out = seg.segment(
        'mi presión 120 80 60 pulsos, de mi esposa 110 70 65 pulsos',
      );
      expect(out.map((s) => s.subject), [isNull, 'esposa']);
    });
  });

  group('FIRST-PERSON RESET (a family marker never swallows my own readings)', () {
    test('"me tomé la presión" after a mamá clause files the BP to the USER', () {
      final out = seg.segment(
        'mi mamá se siente mal, me tomé la presión 130 85 60 pulsos',
      );
      expect(out.length, 2);
      expect(out[0].subject, 'mamá');
      expect(out[0].text, 'se siente mal');
      // The reflexive first-person "me tomé" RESETS the running subject: the
      // reading is MINE, not my mother's.
      expect(out[1].subject, isNull);
      expect(out[1].text, contains('130 85 60 pulsos'));
    });

    test('an explicit "yo" resets after a family reading', () {
      final out = seg.segment('de mi esposa 120/80, yo dormí 7 horas');
      expect(out.length, 2);
      expect(out[0].subject, 'esposa');
      expect(out[0].text, contains('120/80'));
      expect(out[1].subject, isNull, reason: '"yo dormí" is the USER sleeping');
      expect(out[1].text, contains('dormí 7 horas'));
    });

    test('"con mi <rel>" is a COMPANION, not a subject transfer', () {
      // Doing something WITH a family member stays the USER's activity, and the
      // following unmarked reading is the USER's too.
      final out = seg.segment('salí con mi hermano a correr, 122 77 55 pulsos');
      expect(out.length, 2);
      expect(out[0].subject, isNull);
      expect(out[1].subject, isNull);
      expect(out[1].text, '122 77 55 pulsos');
    });

    test('a first-person possessive "mi" (non-relation) resets too', () {
      final out = seg.segment('de mi papá 130 85, revisé mi glucosa 95');
      expect(out.length, 2);
      expect(out[0].subject, 'papá');
      expect(out[1].subject, isNull);
    });

    test('a neutral clause still INHERITS the family subject (no over-reset)', () {
      final out = seg.segment('de mi papá 130 85 70 pulsos, glucosa 190');
      expect(out.length, 2);
      expect(out[1].subject, 'papá',
          reason: 'no first-person marker → forward propagation intact');
    });
  });

  group('clause splitting preserves numeric sequences', () {
    test('commas INSIDE a reading are not clause boundaries', () {
      final out = seg.segment('120, 60, 49 pulsos');
      expect(out.length, 1, reason: 'the reading stays whole');
      expect(out.single.text, '120, 60, 49 pulsos');
    });

    test('mid-reading marker + comma-separated numbers survive together', () {
      final out = seg.segment('esto le salió a mi papá 135, 89, 95 pulsos');
      expect(out.length, 1);
      expect(out.single.subject, 'papá');
      expect(out.single.text, contains('135, 89, 95 pulsos'));
    });

    test('a leading connector after a comma is stripped', () {
      final out = seg.segment('recé el rosario, y medité un rato');
      expect(out.length, 2);
      expect(out[1].text, 'medité un rato', reason: 'the "y " is dropped');
    });

    test('splits on " luego " / " entonces " connectors', () {
      final out = seg.segment('corrí 5km luego recé el rosario');
      expect(out.map((s) => s.text), ['corrí 5km', 'recé el rosario']);
    });
  });

  group('robustness (never crash, never lose content)', () {
    test('empty / blank input yields no segments', () {
      expect(seg.segment(''), isEmpty);
      expect(seg.segment('   '), isEmpty);
    });

    test('only connectors/punctuation falls back to one whole segment', () {
      final out = seg.segment(', , y ;');
      expect(out.length, 1);
      expect(out.single.subject, isNull);
    });

    test('garbage input does not crash and is user-owned', () {
      final out = seg.segment('!!! ??? ...');
      expect(out, isNotEmpty);
      expect(out.every((s) => s.subject == null), isTrue);
    });
  });
}
