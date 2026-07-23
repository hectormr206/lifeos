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

  // Sampling contract: flutter_gemma's `createChat` defaults to `topK: 1` (pure
  // greedy/argmax), which drives gemma-4 into degenerate "well well well…"
  // repetition loops. Both paths override it, but they INTENTIONALLY DIVERGE:
  //   * text (`generate`)          → 1.0 / 64 / 0.95 (varied, creative)
  //   * image (`generateWithImages`) → 0.7 / 40 / 0.9 (tighter — the flatter
  //     vision logits under 1.0 sampled the `<pad>` control token far too
  //     readily, surfacing as literal "<pad><pad>…"; the lower settings sharply
  //     cut that while still avoiding the greedy loop).
  // There is no injection seam for the native InferenceModel (load() reaches the
  // real FFI and throws on the host), so we assert the contract at the source:
  // the two `createChat` invocations carry the expected per-path sampling, and
  // the seed is varied per call (not a constant).
  group('createChat sampling params', () {
    final source = File(
      'lib/features/local_model/data/flutter_gemma_llm_engine.dart',
    ).readAsStringSync();

    // The first createChat is the text path (`generate`), the second is the
    // vision path (`generateWithImages`) — in source order.
    final chatCalls =
        RegExp(r'await model\.createChat\(([\s\S]*?)\);').allMatches(source).map((m) => m.group(1)!).toList();

    test('there are exactly two createChat calls (text + image paths)', () {
      expect(chatCalls.length, 2);
    });

    test('the TEXT path keeps the creative 1.0 / 64 / 0.95 sampling', () {
      final text = chatCalls[0];
      expect(text, contains('temperature: 1.0'), reason: 'must override the greedy default');
      expect(text, contains('topK: 64'), reason: 'topK: 1 default causes repetition loops');
      expect(text, contains('topP: 0.95'));
    });

    test('the VISION path uses the tighter 0.7 / 40 / 0.9 sampling (anti <pad>)', () {
      final vision = chatCalls[1];
      expect(vision, contains('temperature: 0.7'),
          reason: 'high temperature over-samples control tokens on flat vision logits');
      expect(vision, contains('topK: 40'));
      expect(vision, contains('topP: 0.9'));
    });

    test('both paths override the greedy default and vary the seed per call', () {
      for (final call in chatCalls) {
        expect(call, contains('randomSeed:'));
        // Varied seed via wall-clock millis so replies are non-deterministic.
        expect(call, contains('DateTime.now().millisecondsSinceEpoch'));
        expect(call, contains('0x7fffffff'));
      }
    });
  });

  // Safety net (FIX 1): even with tightened vision sampling, LiteRT-LM can
  // detokenize a special/control token to literal text (a sampled `<pad>`
  // surfacing as "<pad>"). Both generate paths scrub these before returning, so
  // they never reach the user. Asserted directly via the test-only view.
  group('special-token stripping', () {
    test('strips a lone <pad> to empty', () {
      expect(FlutterGemmaLlmEngine.stripSpecialTokensForTest('<pad>'), '');
    });

    test('strips repeated <pad> runs (the reported vision failure)', () {
      expect(
        FlutterGemmaLlmEngine.stripSpecialTokensForTest('<pad><pad><pad>'),
        '',
      );
    });

    test('removes <pad> while preserving the surrounding real answer', () {
      expect(
        FlutterGemmaLlmEngine.stripSpecialTokensForTest('Hola<pad> mundo'),
        'Hola mundo',
      );
    });

    test('strips the full Gemma special-token set (eos/bos/turn/unused)', () {
      const raw = '<bos>Texto<start_of_turn><end_of_turn><eos><unused0><unused12>';
      expect(FlutterGemmaLlmEngine.stripSpecialTokensForTest(raw), 'Texto');
    });

    test('leaves ordinary angle-bracket text untouched', () {
      // Not a special token — a legit "<3" or generic markup must survive.
      expect(FlutterGemmaLlmEngine.stripSpecialTokensForTest('a <3 b'), 'a <3 b');
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
