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

    test('tokensPerSec PREFERS the native decode rate when present', () {
      // Wall-clock would read 40/2.0s = 20 tok/s, but the runtime measured a
      // true decode rate of 55 — the diluted wall-clock number must not win.
      const m = GenerationMetrics(
        totalMs: 2000,
        tokensOut: 40,
        backend: LocalLlmBackend.gpu,
        modelId: 'x',
        ttftMs: 300,
        decodeTokensPerSec: 55.0,
      );
      expect(m.tokensPerSec, 55.0);
    });

    test('fallback (no native rate) excludes the TTFT/prefill window, never totalMs', () {
      // No decodeTokensPerSec → fall back to tokensOut / ((totalMs - ttftMs)/1s).
      // 40 tokens, 2000 ms total, 400 ms of which was prefill/TTFT → 1600 ms of
      // decode → 25 tok/s. The OLD (buggy) formula 40/2.0 = 20 must NOT be used.
      const m = GenerationMetrics(
        totalMs: 2000,
        tokensOut: 40,
        backend: LocalLlmBackend.gpu,
        modelId: 'x',
        ttftMs: 400,
      );
      expect(m.tokensPerSec, 25.0);
    });

    test('a zero native decode rate is ignored in favour of the fallback', () {
      const m = GenerationMetrics(
        totalMs: 1000,
        tokensOut: 20,
        backend: LocalLlmBackend.gpu,
        modelId: 'x',
        decodeTokensPerSec: 0,
      );
      // 0 is treated as "not reported" → fallback (no ttft): 20/1.0 = 20.
      expect(m.tokensPerSec, 20.0);
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
        decodeTokensPerSec: 42.0,
        tokensApproximate: true,
      );
      const b = GenerationMetrics(
        totalMs: 1200,
        tokensOut: 24,
        backend: LocalLlmBackend.gpu,
        modelId: 'x',
        ttftMs: 150,
        decodeTokensPerSec: 42.0,
        tokensApproximate: true,
      );
      const different = GenerationMetrics(
        totalMs: 1200,
        tokensOut: 24,
        backend: LocalLlmBackend.gpu,
        modelId: 'x',
        ttftMs: 150,
        decodeTokensPerSec: 99.0, // differs only in the native decode rate
        tokensApproximate: true,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(different)));
    });
  });
}
