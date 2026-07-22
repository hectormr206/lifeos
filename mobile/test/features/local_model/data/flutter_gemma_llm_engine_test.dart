// Proves the inference-engine registration contract of FlutterGemmaLlmEngine
// (roadmap SLICE 1): the injected [initializer] — which in production
// registers the `.litertlm` LiteRtLmEngine with flutter_gemma — runs exactly
// once and BEFORE the first model load, and is not re-run on subsequent calls.
//
// We inject a counting fake initializer via the constructor seam, so no
// flutter_gemma plugin channel / native engine is touched. `load()` itself
// still reaches `FlutterGemma.getActiveModel`, which throws on the host (no
// device / no platform channel); that throw is expected and irrelevant here —
// what matters is that the initializer fired first, once.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/data/flutter_gemma_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Sampling contract (repetition fix): flutter_gemma's `createChat` defaults
  // to `topK: 1` (pure greedy/argmax), which drives gemma-4 into degenerate
  // "well well well…" repetition loops — worst on the vision path. Both the
  // text (`generate`) and image (`generateWithImages`) chats MUST pass Gemma's
  // recommended sampling. There is no injection seam for the native
  // InferenceModel (load() reaches the real FFI and throws on the host), so we
  // assert the contract at the source: both `createChat` invocations carry the
  // four sampling params, and the seed is varied per call (not a constant).
  group('createChat sampling params (anti-repetition)', () {
    final source = File(
      'lib/features/local_model/data/flutter_gemma_llm_engine.dart',
    ).readAsStringSync();

    // Split the two createChat(...) calls apart so each is checked on its own.
    final chatCalls =
        RegExp(r'await model\.createChat\(([\s\S]*?)\);').allMatches(source).map((m) => m.group(1)!).toList();

    test('there are exactly two createChat calls (text + image paths)', () {
      expect(chatCalls.length, 2);
    });

    test('every createChat call sets Gemma-recommended sampling', () {
      for (final call in chatCalls) {
        expect(call, contains('temperature: 1.0'), reason: 'must override the greedy default');
        expect(call, contains('topK: 64'), reason: 'topK: 1 default causes repetition loops');
        expect(call, contains('topP: 0.95'));
        expect(call, contains('randomSeed:'));
      }
    });

    test('the random seed is varied per call, not a fixed constant', () {
      for (final call in chatCalls) {
        // Varied seed via wall-clock millis so replies are non-deterministic.
        expect(call, contains('DateTime.now().millisecondsSinceEpoch'));
        expect(call, contains('0x7fffffff'));
      }
    });
  });

  test('initializer runs exactly once, before load, and is not repeated', () async {
    var initCount = 0;
    final engine = FlutterGemmaLlmEngine(
      const LocalModelConfig(),
      initializer: () async => initCount++,
    );

    // Nothing has touched the engine yet → registration must not have run.
    expect(initCount, 0);

    for (var i = 0; i < 2; i++) {
      try {
        await engine.load();
      } catch (_) {
        // Expected on the host: getActiveModel has no platform channel / no
        // real registered engine. The init-once guarantee is what we assert.
      }
    }

    expect(initCount, 1, reason: 'engine registration must be idempotent');
  });
}
