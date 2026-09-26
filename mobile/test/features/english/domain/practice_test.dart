// Practice with the on-device model: role-plays and writing, briefly corrected.
//
// The model is small (Gemma E2B), so everything it is asked is narrow and
// everything it answers is checked. It plays a role in simple English at the
// learner's level, and afterwards names at most TWO mistakes: correcting
// everything teaches nothing and makes speaking feel like an exam. An answer
// that does not follow the format is reported as "could not review", never
// shown half-parsed.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/english_goal.dart';
import 'package:lifeos/features/english/domain/practice.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';

void main() {
  group('scenarios per goal', () {
    test('every goal has role-plays and writing tasks to choose from', () {
      for (final goal in EnglishGoal.values) {
        expect(roleplaysFor(goal).length, greaterThanOrEqualTo(3),
            reason: goal.name);
        expect(writingTasksFor(goal).length, greaterThanOrEqualTo(3),
            reason: goal.name);
      }
    });

    test('work practice is about clients and projects', () {
      final roles = roleplaysFor(EnglishGoal.work).map((s) => s.role).join(' ');
      expect(roles.toLowerCase(), contains('client'));
    });

    test('ids are unique, so a saved session can point back to its scenario',
        () {
      final ids = [
        for (final g in EnglishGoal.values) ...[
          ...roleplaysFor(g).map((s) => s.id),
          ...writingTasksFor(g).map((t) => t.id),
        ],
      ];
      expect(ids.toSet(), hasLength(ids.length));
    });
  });

  group('the role-play prompt', () {
    final scenario = roleplaysFor(EnglishGoal.everyday).first;

    test('keeps the model in its role, brief, and at the learner level', () {
      final prompt = buildRoleplayPrompt(
        scenario: scenario,
        level: CefrLevel.a2,
        turns: const [],
      );

      expect(prompt, contains(scenario.role));
      expect(prompt, contains('A2'));
      expect(prompt.toLowerCase(), contains('two sentences'));
      expect(prompt.toLowerCase(), contains('do not correct'));
    });

    test('carries the conversation so far, in order', () {
      final prompt = buildRoleplayPrompt(
        scenario: scenario,
        level: CefrLevel.b1,
        turns: const [
          PracticeTurn(fromLearner: false, text: 'Hello! How can I help?'),
          PracticeTurn(fromLearner: true, text: 'I want a table for two.'),
        ],
      );

      expect(prompt.indexOf('How can I help'),
          lessThan(prompt.indexOf('table for two')));
    });

    test('a long conversation keeps only its recent turns', () {
      final turns = [
        for (var i = 0; i < 30; i++)
          PracticeTurn(fromLearner: i.isOdd, text: 'turn number $i'),
      ];
      final prompt = buildRoleplayPrompt(
          scenario: scenario, level: CefrLevel.b1, turns: turns);

      expect(prompt, contains('turn number 29'));
      expect(prompt, isNot(contains('turn number 0\n')));
    });
  });

  group('the feedback', () {
    test('it asks about the learner text only, for at most two mistakes', () {
      final prompt = buildFeedbackPrompt(learnerText: 'I have 30 years.');

      expect(prompt, contains('I have 30 years.'));
      expect(prompt.toLowerCase(), contains('at most two'));
      expect(prompt, contains('WRONG:'));
      // Both found against the real E2B: a RIGHT that fixed one mistake and
      // kept another in the same sentence, and a WHY written in English.
      expect(prompt, contains('EVERY mistake'));
      expect(prompt, contains('en español'));
    });

    test('a well-formed answer becomes corrections', () {
      final feedback = parseFeedback('''
WRONG: I have 30 years.
RIGHT: I am 30 years old.
WHY: En inglés la edad se dice con "to be", no con "to have".
''')!;

      expect(feedback.corrections, hasLength(1));
      final c = feedback.corrections.single;
      expect(c.wrong, 'I have 30 years.');
      expect(c.right, 'I am 30 years old.');
      expect(c.why, contains('to be'));
    });

    test('what is shown is written English, even if the model wrote lowercase',
        () {
      // Seen on the Pixel: the prompt says to ignore capitals, and E2B then
      // writes its own sentences in lowercase, "yesterday i finished".
      final c = parseFeedback('WRONG: yesterday i finish the login page\n'
              "RIGHT: yesterday i finished it, and i'm happy with my iPhone app\n"
              'WHY: x')!
          .corrections
          .single;

      expect(c.wrong, 'Yesterday I finish the login page');
      expect(c.right, "Yesterday I finished it, and I'm happy with my iPhone app");
      expect(parseFeedback('WRONG: x i.e. y\nRIGHT: z i.e. y\nWHY: w')!
          .corrections.single.right, 'Z i.e. y');
    });

    test('the same correction twice is shown once', () {
      // Seen on the Pixel: E2B repeated its one correction, and the screen
      // showed two identical cards.
      const pair = 'WRONG: yesterday i finish it\n'
          'RIGHT: yesterday i finished it\nWHY: pasado';
      expect(parseFeedback('$pair\n$pair')!.corrections, hasLength(1));
    });

    test('"no mistakes" is a real answer, not a failure', () {
      final feedback = parseFeedback('NO MISTAKES')!;

      expect(feedback.corrections, isEmpty);
    });

    test('never more than two, whatever the model says', () {
      final block = [
        for (var i = 0; i < 4; i++) 'WRONG: a$i\nRIGHT: b$i\nWHY: c',
      ].join('\n');

      expect(parseFeedback(block)!.corrections, hasLength(2));
    });

    test('a correction that changes nothing is dropped', () {
      final feedback = parseFeedback('WRONG: I am here.\nRIGHT: I am here.\nWHY: x')!;

      expect(feedback.corrections, isEmpty);
    });

    test('an answer in some other shape could not be reviewed', () {
      expect(parseFeedback('Great job! Your English is very good.'), isNull);
      expect(parseFeedback(''), isNull);
    });
  });
}
