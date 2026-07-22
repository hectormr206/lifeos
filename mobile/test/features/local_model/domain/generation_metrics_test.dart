// Proves GenerationMetrics' derived tokens/s, honesty flag, and value equality
// (roadmap SLICE 1 per-response metrics). Pure value object — no engine.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

void main() {
  group('GenerationMetrics', () {
    test('tokensPerSec derives from tokensOut over wall-clock totalMs', () {
      const m = GenerationMetrics(
        totalMs: 2000,
        tokensOut: 40,
        backend: LocalLlmBackend.gpu,
        modelId: 'gemma-4-E2B-it.litertlm',
      );
      // 40 tokens in 2.0 s → 20 tok/s.
      expect(m.tokensPerSec, 20);
    });

    test('tokensPerSec is zero on a sub-millisecond run (no div-by-zero)', () {
      const m = GenerationMetrics(
        totalMs: 0,
        tokensOut: 5,
        backend: LocalLlmBackend.cpu,
        modelId: 'x',
      );
      expect(m.tokensPerSec, 0);
    });

    test('defaults: ttft null and tokens are NOT flagged approximate', () {
      const m = GenerationMetrics(
        totalMs: 100,
        tokensOut: 1,
        backend: LocalLlmBackend.npu,
        modelId: 'x',
      );
      expect(m.ttftMs, isNull);
      expect(m.tokensApproximate, isFalse);
    });

    test('value-equality compares every field', () {
      const a = GenerationMetrics(
        totalMs: 1200,
        tokensOut: 24,
        backend: LocalLlmBackend.gpu,
        modelId: 'x',
        ttftMs: 150,
        tokensApproximate: true,
      );
      const b = GenerationMetrics(
        totalMs: 1200,
        tokensOut: 24,
        backend: LocalLlmBackend.gpu,
        modelId: 'x',
        ttftMs: 150,
        tokensApproximate: true,
      );
      const different = GenerationMetrics(
        totalMs: 1200,
        tokensOut: 25,
        backend: LocalLlmBackend.gpu,
        modelId: 'x',
        ttftMs: 150,
        tokensApproximate: true,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(different)));
    });
  });
}
