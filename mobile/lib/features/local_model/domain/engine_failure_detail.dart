import 'local_llm_engine.dart';

/// Which engine call threw. The user cannot act differently on the two — which
/// is exactly why [SummaryFailure.modelUnavailable] merges them into one
/// sentence — but ANYONE diagnosing the failure needs to know, and on this
/// user's device there is no other way to find out.
enum LlmEngineCall {
  /// [LocalLlmEngine.load] — the weights were not brought into memory.
  load,

  /// [LocalLlmEngine.generate] / `generateWithImages` — the model was loaded
  /// and the completion itself blew up.
  generate,
}

/// The underlying exception, preserved so it can reach a human.
///
/// WHY THIS EXISTS. Every model failure in this app funnels into one
/// plain-language sentence ("Hay un modelo instalado, pero no se pudo usar…").
/// That sentence is right: it is what the reader can act on. But it was ALSO
/// the end of the evidence — the real exception died in a `catch (_)`, and on
/// the device where it actually happens there is no way to recover it:
/// `flutter test` has no plugin channel, adb logcat from a terminal app shows
/// only that app's own logs, and there is no second device.
///
/// So the exception survives to a collapsed "technical details" affordance the
/// user can expand and quote back. It is never the headline and never shown by
/// default — this type carries evidence, not user-facing copy, which is why
/// nothing in it is translated.
class EngineFailureDetail {
  const EngineFailureDetail({
    required this.call,
    required this.errorType,
    required this.message,
    this.backend,
  });

  /// Captures [error] as the detail for [call].
  ///
  /// If [error] already carries a detail (an [LlmEngineException] thrown by the
  /// engine, which knew the backend and, after a fallback, BOTH attempts), that
  /// richer detail is kept as-is rather than re-wrapped into a poorer one.
  factory EngineFailureDetail.from(
    LlmEngineCall call,
    Object error, {
    LocalLlmBackend? backend,
  }) {
    if (error is LlmEngineException) return error.detail;
    return EngineFailureDetail(
      call: call,
      errorType: error.runtimeType.toString(),
      message: truncate(error.toString()),
      backend: backend,
    );
  }

  /// Cap on the preserved message. A native runtime can dump a wall of text;
  /// past this the panel and the clipboard stop being usable. The cut is
  /// MARKED (see [truncate]) — evidence that looks complete and is not would be
  /// worse than evidence that admits where it stops.
  static const int maxMessageChars = 800;

  /// [s] cut to [maxMessageChars], with an explicit ellipsis when it was cut.
  static String truncate(String s) {
    final trimmed = s.trim();
    if (trimmed.length <= maxMessageChars) return trimmed;
    return '${trimmed.substring(0, maxMessageChars)}…';
  }

  final LlmEngineCall call;

  /// The exception's runtime type (`PlatformException`, `StateError`, …).
  final String errorType;

  /// The exception's own message, truncated by [truncate].
  final String message;

  /// The backend that was being asked for when it threw, when observed. Null
  /// means "not observed" — never a guess at the configured default.
  final LocalLlmBackend? backend;

  /// The whole detail as ONE copyable block: the call, the backend (when
  /// known), the exception type, then the message.
  String get text {
    final head = [call.name, if (backend != null) backend!.name, errorType].join(' · ');
    return '$head\n$message';
  }

  @override
  bool operator ==(Object other) =>
      other is EngineFailureDetail &&
      other.call == call &&
      other.errorType == errorType &&
      other.message == message &&
      other.backend == backend;

  @override
  int get hashCode => Object.hash(call, errorType, message, backend);

  @override
  String toString() => 'EngineFailureDetail($text)';
}

/// What [LocalLlmEngine] implementations throw when they can attach richer
/// evidence than the caller could reconstruct — the backend that was asked for,
/// and (after a backend fallback) BOTH attempts' errors.
///
/// [toString] renders the whole detail, so existing callers that merely
/// interpolate the error into a message get MORE information, not less.
class LlmEngineException implements Exception {
  const LlmEngineException(this.detail);

  final EngineFailureDetail detail;

  @override
  String toString() => detail.text;
}
