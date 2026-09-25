// The practice prompts, wired to the on-device model.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/practice_service.dart';
import 'package:lifeos/features/english/domain/english_goal.dart';
import 'package:lifeos/features/english/domain/practice.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

void main() {
  final scenario = roleplaysFor(EnglishGoal.everyday).first;
  const turns = [PracticeTurn(fromLearner: true, text: 'A table for two.')];

  group('the partner replies', () {
    test('with the role-play prompt, and the reply trimmed', () async {
      final engine = FakeLocalLlmEngine(reply: (_) => '  Sure! Follow me.  ');

      final reply = await PracticeService(engine)
          .reply(scenario: scenario, level: CefrLevel.a2, turns: turns);

      expect(reply, 'Sure! Follow me.');
      expect(engine.prompts.single, contains(scenario.role));
    });

    test('a "You:" the model put in front is taken off', () async {
      final engine = FakeLocalLlmEngine(reply: (_) => 'You: Sure! Follow me.');

      expect(
        await PracticeService(engine)
            .reply(scenario: scenario, level: CefrLevel.a2, turns: turns),
        'Sure! Follow me.',
      );
    });

    test('no reply or a failing model is null, never an exception', () async {
      final empty = FakeLocalLlmEngine(reply: (_) => '   ');
      final broken = FakeLocalLlmEngine(generateShouldFail: true);

      expect(
          await PracticeService(empty)
              .reply(scenario: scenario, level: CefrLevel.a2, turns: turns),
          isNull);
      expect(
          await PracticeService(broken)
              .reply(scenario: scenario, level: CefrLevel.a2, turns: turns),
          isNull);
    });
  });

  group('the review', () {
    test('asks about the learner text, at a low temperature', () async {
      final engine = FakeLocalLlmEngine(reply: (_) => 'NO MISTAKES');

      final feedback = await PracticeService(engine).review('I am here.');

      expect(feedback!.corrections, isEmpty);
      expect(engine.prompts.single, contains('I am here.'));
      expect(engine.generateSampling.single.$1, kReviewTemperature);
    });

    test('an answer out of format is null, so the screen can say so',
        () async {
      final engine = FakeLocalLlmEngine(reply: (_) => 'Great job!');

      expect(await PracticeService(engine).review('I am here.'), isNull);
    });

    test('a failing model is null too', () async {
      final engine = FakeLocalLlmEngine(generateShouldFail: true);

      expect(await PracticeService(engine).review('I am here.'), isNull);
    });
  });
}
