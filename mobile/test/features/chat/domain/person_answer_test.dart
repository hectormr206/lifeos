// Answering "¿quién es X?" from the graph, without asking the model.
//
// Measured on the device: with "mi hermana se llama Laura" stored and the
// recall provably correct (facts=2, both about Laura), the ~2B model still
// answered "Laura es tu esposa". The context was right and the GENERATION was
// wrong — no amount of prompt work fixes that.
//
// So a kinship question is answered from the stored text directly. The capture
// layer already short-circuits this way when it records a health value; this is
// the same idea for the one question a small model gets confidently wrong.
//
// It answers ONLY when it is certain: a bond it can read, or nothing stored at
// all. Anything ambiguous falls through to the model, because a deterministic
// wrong answer is worse than a model's hedge.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/person_answer.dart';

void main() {
  group('recognising the question', () {
    test('"quién es X"', () {
      expect(personAskedAbout('quien es Laura'), 'Laura');
      expect(personAskedAbout('¿Quién es Ana?'), 'Ana');
    });

    test('"qué relación tengo con X"', () {
      expect(personAskedAbout('que relacion tengo con Roberto'), 'Roberto');
    });

    test('English', () {
      expect(personAskedAbout('who is Ana'), 'Ana');
      expect(personAskedAbout('what relationship do I have with Ana'), 'Ana');
    });

    test('a question about something else is not a person question', () {
      expect(personAskedAbout('cuanto pese ayer'), isNull);
      expect(personAskedAbout('que tengo mañana'), isNull);
    });

    test('a statement is never a question', () {
      // "Laura es mi hermana" must reach the capture layer, not this one.
      expect(personAskedAbout('Laura es mi hermana'), isNull);
    });
  });

  group('answering from what is stored', () {
    test('it reads the bond out of the remembered line', () {
      expect(
        answerAboutPerson(
          name: 'Laura',
          facts: ['tu hermana se llama Laura'],
          languageCode: 'es',
        ),
        'Laura es tu hermana.',
      );
    });

    test('it does not confuse one bond with another', () {
      // THE bug: "Laura es tu esposa" with only sister facts in context.
      final answer = answerAboutPerson(
        name: 'Laura',
        facts: ['tu hermana se llama Laura', 'tu esposa se llama Ana'],
        languageCode: 'es',
      );

      expect(answer, contains('hermana'));
      expect(answer, isNot(contains('esposa')));
    });

    test('nothing stored says so plainly', () {
      expect(
        answerAboutPerson(name: 'Mariana', facts: [], languageCode: 'es'),
        'No sé quién es Mariana.',
      );
    });

    test('a fact with no bond word falls through to the model', () {
      // "Ana trabaja en marketing" is about her but names no relationship;
      // the model can phrase that better than a template.
      expect(
        answerAboutPerson(
          name: 'Ana',
          facts: ['Ana trabaja en marketing'],
          languageCode: 'es',
        ),
        isNull,
      );
    });

    test('two different bonds for one person fall through', () {
      // Genuinely ambiguous: let the model hedge rather than pick.
      expect(
        answerAboutPerson(
          name: 'Ana',
          facts: ['tu esposa se llama Ana', 'tu jefa se llama Ana'],
          languageCode: 'es',
        ),
        isNull,
      );
    });

    test('English answers in English', () {
      expect(
        answerAboutPerson(
          name: 'Ana',
          facts: ['your wife is called Ana'],
          languageCode: 'en',
        ),
        'Ana is your wife.',
      );
    });
  });

  group('learning a bond from a statement', () {
    // The other half of the hole. The QUESTION was answered correctly ("No sé
    // quién es Laura") precisely because the STATEMENT that should have taught
    // it was never stored. Being told about someone's sister and forgetting is
    // the plainest failure a memory can have.

    test('"mi hermana se llama Laura"', () {
      final r = kinshipStatement('mi hermana se llama Laura')!;
      expect(r.bond, 'hermana');
      expect(r.name, 'Laura');
    });

    test('"Laura es mi hermana"', () {
      final r = kinshipStatement('Laura es mi hermana')!;
      expect(r.bond, 'hermana');
      expect(r.name, 'Laura');
    });

    test('English', () {
      final r = kinshipStatement('my sister is called Laura')!;
      expect(r.bond, 'hermana');
      expect(r.name, 'Laura');
    });

    test('a QUESTION is never a statement', () {
      // Storing the question as a fact would teach it something nobody said.
      expect(kinshipStatement('¿quién es Laura?'), isNull);
      expect(kinshipStatement('que relacion tengo con Laura'), isNull);
    });

    test('a sentence with no bond word is not one', () {
      expect(kinshipStatement('Laura trabaja en marketing'), isNull);
    });

    test('a lowercase word is not taken for a name', () {
      expect(kinshipStatement('mi hermana se llama como mi abuela'), isNull);
    });
  });
}
