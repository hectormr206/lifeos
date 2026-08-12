// The evidence contract. `SummaryFailure.modelUnavailable` deliberately merges
// "load() threw" and "generate() threw" — the reader cannot act differently on
// the two, so ONE sentence is the right headline. But merging them threw away
// the only evidence that exists on a device we cannot reach: no `flutter test`
// plugin channel, no usable adb logcat, no spare phone.
//
// [EngineFailureDetail] is what survives the merge: which call threw, what type
// the exception was, what it said, and which backend was being asked for. It is
// never the headline — it is the thing the user can expand and quote back.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/engine_failure_detail.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

void main() {
  group('EngineFailureDetail.from', () {
    test('records WHICH call threw, the exception type, and its message', () {
      final detail = EngineFailureDetail.from(
        LlmEngineCall.load,
        StateError('no active inference model'),
        backend: LocalLlmBackend.gpu,
      );

      expect(detail.call, LlmEngineCall.load);
      expect(detail.errorType, 'StateError');
      expect(detail.message, contains('no active inference model'));
      expect(detail.backend, LocalLlmBackend.gpu);
    });

    test('distinguishes a generate() throw from a load() throw', () {
      final detail = EngineFailureDetail.from(
        LlmEngineCall.generate,
        Exception('boom'),
      );

      expect(detail.call, LlmEngineCall.generate);
      // No backend was in play for this capture: report nothing rather than
      // guess the configured default and present it as observed fact.
      expect(detail.backend, isNull);
    });

    test('keeps an already-built detail instead of re-wrapping it', () {
      // The engine captures the detail closest to the throw (it knows the
      // backend); the notifier must not overwrite that with a poorer one.
      final inner = EngineFailureDetail.from(
        LlmEngineCall.load,
        Exception('gpu delegate failed'),
        backend: LocalLlmBackend.gpu,
      );
      final outer = EngineFailureDetail.from(
        LlmEngineCall.generate,
        LlmEngineException(inner),
      );

      expect(outer, inner);
    });
  });

  group('text', () {
    test('names the call, the type and the message, all copyable in one block', () {
      final detail = EngineFailureDetail.from(
        LlmEngineCall.load,
        StateError('model file not found at path: /data/x.litertlm'),
        backend: LocalLlmBackend.gpu,
      );

      expect(detail.text, contains('load'));
      expect(detail.text, contains('gpu'));
      expect(detail.text, contains('StateError'));
      expect(detail.text, contains('/data/x.litertlm'));
    });

    test('omits the backend line when no backend was observed', () {
      final detail = EngineFailureDetail.from(LlmEngineCall.generate, Exception('x'));
      expect(detail.text, isNot(contains('gpu')));
      expect(detail.text, isNot(contains('cpu')));
    });
  });

  test('a very long message is truncated, and SAYS it was truncated', () {
    // A native runtime can dump a wall of text. The panel (and the clipboard)
    // stay usable, but a silent cut would make the user quote back evidence
    // that looks complete and is not.
    final detail = EngineFailureDetail.from(
      LlmEngineCall.load,
      Exception('x' * (EngineFailureDetail.maxMessageChars * 3)),
    );

    expect(detail.message.length, lessThan(EngineFailureDetail.maxMessageChars + 40));
    expect(detail.message, endsWith('…'));
  });

  test('two details built from the same failure are equal', () {
    final a = EngineFailureDetail.from(LlmEngineCall.load, Exception('same'));
    final b = EngineFailureDetail.from(LlmEngineCall.load, Exception('same'));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
