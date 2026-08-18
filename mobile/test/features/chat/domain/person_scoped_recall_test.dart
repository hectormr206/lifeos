// A fact about one person must never answer a question about another.
//
// Measured on the device, over four builds: asked about a name with nothing
// stored, the model took the only person-fact in the block and attached it —
// "Mariana es tu esposa" about someone it had never seen. Prompt rules made it
// better, then worse, then worse again; a ~2B model will not police attribution
// reliably, and each new rule broke one that already worked.
//
// So the block never carries the material for that mistake. This is the
// deterministic half — code doing what a rule could not.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/chat_context_builder.dart';

void main() {
  group('names in a remembered line', () {
    test('a person-fact names that person', () {
      expect(properNounsInMessage('x Ana es tu esposa'), contains('Ana'));
    });

    test('a measurement names nobody', () {
      // Facts about no one must always survive the filter: they cannot be
      // attributed to the wrong person because they are about no person.
      expect(properNounsInMessage('x peso 82 kg'), isEmpty);
      expect(properNounsInMessage('x presión 120/80'), isEmpty);
    });

    test('a lowercase word is not a name', () {
      expect(properNounsInMessage('x cita con el dentista'), isEmpty);
    });

    test('two people in one line are both found', () {
      expect(
        properNounsInMessage('x cena con Ana y Roberto'),
        containsAll(['Ana', 'Roberto']),
      );
    });

    test('an accented name is found', () {
      expect(properNounsInMessage('x Sofía es tu hija'), contains('Sofía'));
    });
  });
}
