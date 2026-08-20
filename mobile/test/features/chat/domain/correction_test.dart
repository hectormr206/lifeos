// Correcting Axi by talking to it.
//
// The data goes IN by talking — "su hijo Mateo tiene 8 años" — and until now
// the only way to fix it was to go find the row and edit it by hand. Almost
// nobody does that, so the errors stay.
//
// And a wrong fact is not inert: it gets repeated. The day Axi tells someone
// their friend's son is a year younger, in front of the friend, the trust in
// the whole memory is gone. You only get to break that once.
//
// So a correction is recognised in Dart, before anything tries to STORE the
// sentence as a new fact — which is exactly what happened to "no, Mateo tiene
// 9": it was captured as a second, contradictory entry.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/correction.dart';

void main() {
  group('recognising a correction', () {
    for (final phrase in const [
      'no, Mateo tiene 9',
      'no es 8, son 9',
      'me equivoqué, tiene 9',
      'corrige: Mateo tiene 9',
      'perdón, quise decir 9',
    ]) {
      test('"$phrase" es una corrección', () {
        expect(looksLikeCorrection(phrase), isTrue);
      });
    }

    for (final phrase in const [
      'Mateo tiene 9 años',
      'no me acuerdo',
      'no sé qué hacer',
      '¿cuántos años tiene Mateo?',
    ]) {
      test('"$phrase" NO lo es', () {
        expect(looksLikeCorrection(phrase), isFalse);
      });
    }
  });

  group('what it corrects', () {
    test('it carries the new wording, without the correction prefix', () {
      // Stored with "no, " in front, the fact reads as a denial for ever.
      expect(correctionPayload('no, Mateo tiene 9'), 'Mateo tiene 9');
    });

    test('"me equivoqué" is stripped too', () {
      expect(correctionPayload('me equivoqué, tiene 9'), 'tiene 9');
    });

    test('an empty correction carries nothing', () {
      // "no, me equivoqué" alone says something is wrong but not what is
      // right. Storing a blank would erase the original with nothing.
      expect(correctionPayload('me equivoqué'), isNull);
    });
  });

  group('the rule that matters', () {
    test('a correction is never treated as a new fact', () {
      // Measured behaviour before this existed: the correction was captured
      // as a SECOND entry, so the graph held both "8 años" and "9 años" and
      // recall could return either.
      expect(looksLikeCorrection('no, Mateo tiene 9'), isTrue);
      expect(correctionPayload('no, Mateo tiene 9'), isNot(contains('no,')));
    });
  });
}
