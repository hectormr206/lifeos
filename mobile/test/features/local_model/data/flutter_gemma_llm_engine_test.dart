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
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/data/flutter_gemma_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
