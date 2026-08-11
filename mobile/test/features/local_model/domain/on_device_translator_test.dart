// Proves the reusable OnDeviceTranslator.
//
// THE REPORTED BUG: "some news items don't get translated". The cause is not
// random. The whole source went to the model as ONE numbered batch, and the
// engine caps generation at `maxOutputTokens`; a batch whose translation is
// longer than that cap comes back with its LAST lines missing, and every
// missing line used to be silently kept in its original language. The tail of
// a source was therefore the part that stayed untranslated — every time.
//
// Two rules close it: batches are bounded (by item count AND by size), and a
// slot that still comes back missing is retried ON ITS OWN before anyone
// settles for the original text.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/on_device_translator.dart';

import '../support/fake_local_llm_engine.dart';

void main() {
  test('translates a small batch with ONE call and maps numbered lines back', () async {
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (_) => '1. Hola mundo\n2. Adiós',
    );
    final translator = OnDeviceTranslator(engine);

    final out = await translator.translate(['Hello world', 'Goodbye'], languageCode: 'es');

    expect(out, ['Hola mundo', 'Adiós']);
    expect(engine.loadCount, 1, reason: 'loads the model once');
    expect(engine.generateCount, 1, reason: 'ONE batched call for a small list');
    expect(engine.generateSampling.single, (0.3, 20, 0.9), reason: 'light translation sampling');
  });

  test('a long list is split into bounded batches, never one oversized call', () async {
    // Ten items in one call is what overran the output cap and truncated the
    // tail on the phone.
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (prompt) {
        // Echo back a translated line per numbered input line.
        final lines = prompt.split('\n').where((l) => RegExp(r'^\d+\.').hasMatch(l.trim()));
        return lines.map((l) => '${l.trim().split('.').first}. traducido').join('\n');
      },
    );
    final translator = OnDeviceTranslator(engine);

    final out = await translator.translate(
      [for (var i = 0; i < 10; i++) 'Item number $i to translate'],
      languageCode: 'es',
    );

    expect(out.every((t) => t == 'traducido'), isTrue, reason: 'every slot translated');
    expect(engine.generateCount, greaterThan(1), reason: 'the list was split');
    expect(
      engine.prompts.every(
        (p) => RegExp(r'^\d+\.', multiLine: true).allMatches(p).length <=
            OnDeviceTranslator.maxItemsPerBatch,
      ),
      isTrue,
      reason: 'no batch exceeds the item bound',
    );
  });

  test('a slot the model omitted is RETRIED on its own instead of being dropped', () async {
    var call = 0;
    final engine = FakeLocalLlmEngine(
      installed: true,
      reply: (_) {
        call++;
        // First (batched) answer loses line 2 — exactly the truncation the
        // output cap produces. The retry then answers the single item.
        return call == 1 ? '1. Hola' : 'Mundo';
      },
    );
    final translator = OnDeviceTranslator(engine);

    final out = await translator.translate(['Hello', 'World'], languageCode: 'es');

    expect(out, ['Hola', 'Mundo'], reason: 'the missing slot was recovered, not abandoned');
    expect(engine.generateCount, 2, reason: 'one batch + one per-item retry');
  });

  test('a slot still missing after its retry stays null (the caller keeps the original)',
      () async {
    final engine = FakeLocalLlmEngine(installed: true, reply: (_) => '1. Hola');
    final translator = OnDeviceTranslator(engine);

    final out = await translator.translate(['Hello', ''], languageCode: 'es');

    expect(out.first, 'Hola');
    expect(out.last, isNull, reason: 'nothing usable came back → keep the original text');
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
