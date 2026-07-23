// Proves the reusable OnDeviceTranslator: ONE batched call, faithful numbered
// mapping, per-slot fallback (missing line → null), and whole-batch fallback on
// a model failure (all-null) — never throwing.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/on_device_translator.dart';

import '../support/fake_local_llm_engine.dart';

void main() {
  test('translates a batch with ONE call and maps numbered lines back', () async {
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (_) => '1. Hola mundo\n2. Adiós',
    );
    final translator = OnDeviceTranslator(engine);

    final out = await translator.translate(['Hello world', 'Goodbye'], languageCode: 'es');

    expect(out, ['Hola mundo', 'Adiós']);
    expect(engine.loadCount, 1, reason: 'loads the model once');
    expect(engine.generateCount, 1, reason: 'ONE batched call for the whole list');
    expect(engine.generateSampling.single, (0.3, 20, 0.9), reason: 'light translation sampling');
  });

  test('keeps a slot null when the model omits its numbered line', () async {
    final engine = FakeLocalLlmEngine(installed: true, reply: (_) => '1. Hola');
    final translator = OnDeviceTranslator(engine);

    final out = await translator.translate(['Hello', 'World'], languageCode: 'es');

    expect(out, ['Hola', null], reason: 'missing line 2 → null → caller keeps original');
  });

  test('returns all-null (never throws) when the model call fails', () async {
    final engine = FakeLocalLlmEngine(installed: true, generateShouldFail: true);
    final translator = OnDeviceTranslator(engine);

    final out = await translator.translate(['Hello', 'World'], languageCode: 'es');

    expect(out, [null, null]);
  });

  test('an empty input needs no model call', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    final translator = OnDeviceTranslator(engine);

    expect(await translator.translate(const [], languageCode: 'es'), isEmpty);
    expect(engine.generateCount, 0);
  });
}
