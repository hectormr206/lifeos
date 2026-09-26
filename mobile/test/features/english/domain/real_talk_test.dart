// Getting ready for a real conversation, and learning from it afterwards.
//
// From B1 on, people are what the app cannot replace. What it can do is the
// before and the after: useful phrases and likely questions before a real
// call, a rehearsal with the model playing the other person, and afterwards
// the natural English for what the learner wanted to say and could not.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/real_talk.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';

void main() {
  group('before: phrases and likely questions', () {
    test('the prompt carries the situation and the level', () {
      final prompt = buildPrepPrompt(
        situation: 'Mañana tengo llamada con un cliente sobre su tienda en línea',
        level: CefrLevel.b1,
      );

      expect(prompt, contains('tienda en línea'));
      expect(prompt, contains('B1'));
      expect(prompt, contains('PHRASE:'));
      expect(prompt, contains('QUESTION:'));
    });

    test('a well-formed answer becomes phrases and questions', () {
      final prep = parsePrep('''
PHRASE: Thanks for your time today.
PHRASE: Can you tell me more about your store?
QUESTION: How much will it cost?
QUESTION: When can you start?
''')!;

      expect(prep.phrases, [
        'Thanks for your time today.',
        'Can you tell me more about your store?',
      ]);
      expect(prep.questions, ['How much will it cost?', 'When can you start?']);
    });

    test('never more than five phrases and three questions', () {
      final answer = [
        for (var i = 0; i < 8; i++) 'PHRASE: p$i',
        for (var i = 0; i < 6; i++) 'QUESTION: q$i',
      ].join('\n');

      final prep = parsePrep(answer)!;
      expect(prep.phrases, hasLength(5));
      expect(prep.questions, hasLength(3));
    });

    test('without a single phrase there is nothing to prepare with', () {
      expect(parsePrep('Good luck with your call!'), isNull);
    });

    test('the rehearsal casts the model as the other person', () {
      final scenario = rehearsalScenario(
        situation: 'Llamada con un cliente sobre su tienda en línea',
        prep: const Prep(
          phrases: ['Hi!'],
          questions: ['How much will it cost?'],
        ),
      );

      expect(scenario.role, contains('tienda en línea'));
      expect(scenario.opening, 'How much will it cost?',
          reason: 'it opens with a question the learner prepared for');
    });
  });

  group('after: what they wanted to say', () {
    // A first design asked the model to read the learner's free notes and
    // find what to fix. Against the real Gemma E2B it translated the notes
    // themselves ("I couldn't say that..."), invented items and ignored
    // "NOTHING". So the learner writes each thing they wanted to say on its
    // own, and the model does one narrow task per thing, like the gloss.
    test('the prompt asks for what to SAY to the other person, in one line',
        () {
      final prompt = buildRephrasePrompt(
        wanted: 'que el proyecto se retrasó porque no mandaron las fotos',
        situation: 'Llamada con un cliente',
      );

      expect(prompt, contains('no mandaron las fotos'));
      expect(prompt, contains('Llamada con un cliente'));
      expect(prompt.toLowerCase(), contains('directly to the other person'));
      expect(prompt.toLowerCase(), contains('one line'));
    });

    test('the answer is its first real line, unquoted', () {
      expect(parseRephrase('\n"The project was delayed because we were still '
              'waiting for the photos."\nmore'),
          'The project was delayed because we were still waiting for the photos.');
    });

    test('an empty answer is nothing', () {
      expect(parseRephrase('  '), isNull);
    });

    test('the things wanted are the lines written, at most three', () {
      expect(
        wantedLines('que se retrasó\n\n  el precio aproximado \nuno\ndos'),
        ['que se retrasó', 'el precio aproximado', 'uno'],
      );
    });
  });

  group('the phrases, cleaned', () {
    test('quotes the model adds around a phrase are taken off', () {
      final prep = parsePrep('PHRASE: "Thanks for your time."\nQUESTION: "When?"')!;

      expect(prep.phrases.single, 'Thanks for your time.');
      expect(prep.questions.single, 'When?');
    });
  });
}
