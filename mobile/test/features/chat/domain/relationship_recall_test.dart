// Relationships have to reach the prompt, or Axi cannot answer about people.
//
// Measured on the test Pixel with 840:
//
//   "¿cómo se llama mi esposa?"      -> "Se llama Ana."          ✅
//   "¿qué relación tengo con Ana?"   -> "no está en la memoria"  ❌
//
// Both facts live in the graph — the 3D brain draws the edge — but the recall
// block dropped every node that was not `kind == 'fact'`, so the EDGES never
// travelled. The bond was visible on screen and invisible to the model.
//
// This suite pins the rendering of a relationship into a recall line. The
// retrieval itself is exercised end to end by `chat_context_builder` tests; here
// the concern is that a bond, once found, is expressed in a sentence the model
// can use.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/chat_context_builder.dart';
import 'package:lifeos/features/memory/domain/recall_block.dart';

void main() {
  group('a bond is rendered as something the model can read', () {
    test('subject and person become one plain sentence', () {
      final line = describeRelationship(
        subject: 'esposa',
        personLabel: 'Ana',
        languageCode: 'es',
      );

      // Second person, because the memory holds the USER's life — the same rule
      // that stopped Axi answering "Ana es mi esposa".
      expect(line, contains('Ana'));
      expect(line, contains('esposa'));
      expect(line.toLowerCase(), contains('tu '));
      expect(line.toLowerCase(), isNot(contains('mi ')));
    });

    test('an unnamed bond still says who it is about', () {
      final line = describeRelationship(
        subject: null,
        personLabel: 'Ana',
        languageCode: 'es',
      );

      expect(line, contains('Ana'));
    });

    test('English installs read naturally too', () {
      final line = describeRelationship(
        subject: 'wife',
        personLabel: 'Ana',
        languageCode: 'en',
      );

      expect(line.toLowerCase(), contains('your'));
      expect(line, contains('Ana'));
    });

    test('it never invents a bond it was not given', () {
      final line = describeRelationship(
        subject: null,
        personLabel: 'Ana',
        languageCode: 'es',
      );

      // No guessing "amiga", "conocida" or anything else: an invented
      // relationship about a real person is exactly the kind of fabrication
      // this codebase forbids.
      expect(line.toLowerCase(), isNot(contains('amig')));
      expect(line.toLowerCase(), isNot(contains('conocid')));
    });
  });

  group('bonds sit above the facts, and neither displaces the other', () {
    test('a relationship line and a fact both survive', () {
      final block = composeMemoryBlock(
        relationships: [
          describeRelationship(
            subject: 'esposa',
            personLabel: 'Ana',
            languageCode: 'es',
          ),
        ],
        factsBlock: 'MEMORIA RELEVANTE:\n- peso 82 kg',
      );

      expect(block, contains('Ana'));
      expect(block, contains('esposa'));
      expect(block, contains('peso 82 kg'),
          reason: 'relationships must not push the ordinary facts out');
      // Bonds first: they are the context that makes the rest readable.
      expect(block.indexOf('Ana'), lessThan(block.indexOf('peso 82 kg')));
    });

    test('no bonds and no facts is an EMPTY block, not a heading', () {
      // An empty "PERSONAS Y VÍNCULOS:" would tell the model it has memory and
      // that it is blank — which invites "no tengo tus datos".
      expect(composeMemoryBlock(relationships: [], factsBlock: '   '), '');
    });

    test('bonds alone still produce a block', () {
      final block = composeMemoryBlock(
        relationships: ['Tu esposa es Ana.'],
        factsBlock: '',
      );

      expect(block, contains('Ana'));
    });
  });

  group('a name in the question is enough to find the person', () {
    // Measured on 841: "¿quién es Ana?" answered "Ana es tu esposa", but
    // "¿qué relación tengo con Ana?" did not — the recall was dominated by
    // "relación" and never surfaced her. A feature that works only when the
    // question happens to be phrased around the name works by luck.

    test('it picks the name out of a question about a relationship', () {
      expect(properNounsInMessage('que relacion tengo con Ana'), contains('Ana'));
    });

    test('the opening word is never taken for a name', () {
      // "Quién" starts the sentence and is capitalised; it names nobody.
      expect(properNounsInMessage('Quién es Ana'), ['Ana']);
    });

    test('lowercase words are left alone', () {
      expect(properNounsInMessage('cuanto pese ayer'), isEmpty);
    });

    test('several names all come back', () {
      expect(
        properNounsInMessage('agenda algo con Ana y Sofía el jueves'),
        containsAll(['Ana', 'Sofía']),
      );
    });

    test('an accented name survives', () {
      expect(properNounsInMessage('quien es Sofía'), contains('Sofía'));
    });
  });
}
