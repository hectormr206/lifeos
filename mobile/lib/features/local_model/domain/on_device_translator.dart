import 'local_llm_engine.dart';

/// Reusable on-device batch translator: renders a list of short strings into a
/// target language with ONE batched [LocalLlmEngine.generate] call, faithfully
/// (translate, don't rewrite) and with per-slot fallback.
///
/// Contract:
///   * Returns a list the SAME length as the input.
///   * Each entry is the translated text, or `null` when that slot could not be
///     translated (the model omitted/blanked its line, or the whole batch
///     failed) — callers keep the ORIGINAL text for a null slot, so a source is
///     never blanked and never dropped.
///   * Never throws: a model/load failure degrades to an all-null result.
///
/// Feature-agnostic on purpose (the morning briefing packs its `title ||| brief`
/// batching ON TOP of this; future features can reuse it as-is).
class OnDeviceTranslator {
  const OnDeviceTranslator(this._engine);

  final LocalLlmEngine _engine;

  /// Light sampling for faithful translation: a low temperature keeps the
  /// rendering faithful while staying above the degenerate-to-empty floor.
  static const double defaultTemperature = 0.3;
  static const int defaultTopK = 20;
  static const double defaultTopP = 0.9;

  /// Translates [inputs] into [languageCode]'s language in one batched call.
  /// See the class contract for the per-slot fallback semantics.
  Future<List<String?>> translate(
    List<String> inputs, {
    required String languageCode,
    double temperature = defaultTemperature,
    int topK = defaultTopK,
    double topP = defaultTopP,
  }) async {
    if (inputs.isEmpty) return const [];
    try {
      await _engine.load();
      final result = await _engine.generate(
        _prompt(inputs, languageCode),
        temperature: temperature,
        topK: topK,
        topP: topP,
      );
      final parsed = parseNumbered(result.text);
      return [
        for (var i = 0; i < inputs.length; i++) _nonEmpty(parsed[i + 1]),
      ];
    } catch (_) {
      // Whole-batch failure: keep every original (all-null result).
      return List<String?>.filled(inputs.length, null);
    }
  }

  /// Builds the batched translation prompt: a numbered list, asking the model to
  /// preserve the numbering (one item per line) and any separators/punctuation
  /// inside a line so [parseNumbered] can map results back to inputs.
  String _prompt(List<String> inputs, String languageCode) {
    final target = languageCode == 'en' ? 'English' : 'neutral Spanish';
    final buffer = StringBuffer();
    for (var i = 0; i < inputs.length; i++) {
      buffer.writeln('${i + 1}. ${inputs[i]}');
    }
    return 'Translate each of the following numbered lines to $target. '
        'Keep the exact same numbering (one item per line) and any separators or '
        'punctuation that appear inside a line. If a line is already in $target, '
        'return it unchanged. Translate only the text, do not add anything.\n\n'
        '$buffer';
  }

  /// Parses a model's numbered response into `{index: content}`. Lines that do
  /// not match the `N. …` shape are ignored so a chatty model never corrupts the
  /// mapping (a missing index → null slot → the caller keeps the original).
  static Map<int, String> parseNumbered(String out) {
    final map = <int, String>{};
    final lineNo = RegExp(r'^\s*(\d+)[.)]\s*(.*)$');
    for (final raw in out.split('\n')) {
      final m = lineNo.firstMatch(raw.trim());
      if (m == null) continue;
      final idx = int.parse(m.group(1)!);
      final rest = m.group(2)!.trim();
      if (rest.isEmpty) continue;
      map[idx] = rest;
    }
    return map;
  }

  static String? _nonEmpty(String? s) {
    final t = s?.trim() ?? '';
    return t.isEmpty ? null : t;
  }
}
