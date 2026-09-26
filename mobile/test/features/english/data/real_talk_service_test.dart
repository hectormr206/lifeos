// The before-and-after of a real conversation, wired to the on-device model.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/data/real_talk_service.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';

import '../../local_model/support/fake_local_llm_engine.dart';

void main() {
  test('preparing returns the phrases and questions', () async {
    final engine = FakeLocalLlmEngine(
        reply: (_) => 'PHRASE: Hello there.\nQUESTION: How much is it?');

    final prep = await RealTalkService(engine)
        .prepare(situation: 'Una llamada', level: CefrLevel.b1);

    expect(prep!.phrases, ['Hello there.']);
    expect(prep.questions, ['How much is it?']);
    expect(engine.prompts.single, contains('Una llamada'));
  });

  test('saying one thing in English returns that line', () async {
    final engine = FakeLocalLlmEngine(reply: (_) => 'It costs extra.');

    expect(
      await RealTalkService(engine)
          .rephrase(wanted: 'que cuesta extra', situation: 'Una llamada'),
      'It costs extra.',
    );
  });

  test('a failing model is null for both, never an exception', () async {
    final engine = FakeLocalLlmEngine(generateShouldFail: true);
    final service = RealTalkService(engine);

    expect(await service.prepare(situation: 'x', level: CefrLevel.a2), isNull);
    expect(await service.rephrase(wanted: 'x', situation: 'y'), isNull);
  });
}
