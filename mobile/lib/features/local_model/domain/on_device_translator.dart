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

  /// Max items in one batched call.
  ///
  /// WHY BOUNDED. The engine caps a generation at `maxOutputTokens`; a batch
  /// whose translation is longer than that cap comes back with its LAST lines
  /// missing, and those slots silently kept their original language. That is
  /// the "some items don't get translated" the user reported, and it hit the
  /// tail of a source every time. Small batches keep each answer well inside
  /// the cap.
  static const int maxItemsPerBatch = 4;

  /// Max input characters in one batched call — the same protection as
  /// [maxItemsPerBatch] for sources whose briefs are long.
  static const int maxCharsPerBatch = 600;

  /// Upper bound on per-slot retries in one call, so a model that answers
  /// nothing useful cannot turn one translation into an unbounded loop.
  static const int maxSlotRetries = 12;

  /// Translates [inputs] into [languageCode]'s language, in bounded batches,
  /// retrying any slot that came back missing ON ITS OWN before giving up on
  /// it. See the class contract for the per-slot fallback semantics.
  Future<List<String?>> translate(
    List<String> inputs, {
    required String languageCode,
    double temperature = defaultTemperature,
    int topK = defaultTopK,
    double topP = defaultTopP,
  }) async {
    if (inputs.isEmpty) return const [];
    final out = List<String?>.filled(inputs.length, null);
    try {
      await _engine.load();
    } catch (_) {
      // No model: keep every original (all-null result).
      return out;
    }

    for (final batch in _batches(inputs)) {
      try {
        final result = await _engine.generate(
          _prompt([for (final i in batch) inputs[i]], languageCode),
          temperature: temperature,
          topK: topK,
          topP: topP,
        );
        final parsed = parseNumbered(result.text);
        for (var j = 0; j < batch.length; j++) {
          out[batch[j]] = _nonEmpty(parsed[j + 1]);
        }
      } catch (_) {
        // This batch produced nothing; its slots fall to the retry below.
      }
    }

    var retries = 0;
    for (var i = 0; i < inputs.length && retries < maxSlotRetries; i++) {
      if (out[i] != null) continue;
      if (inputs[i].trim().isEmpty) continue; // nothing to translate
      retries++;
      out[i] = await _translateOne(inputs[i], languageCode, temperature, topK, topP);
    }
    return out;
  }

  /// Index groups for the batched calls, bounded by item count AND size.
  List<List<int>> _batches(List<String> inputs) {
    final batches = <List<int>>[];
    var current = <int>[];
    var chars = 0;
    for (var i = 0; i < inputs.length; i++) {
      final length = inputs[i].length;
      if (current.isNotEmpty &&
          (current.length >= maxItemsPerBatch || chars + length > maxCharsPerBatch)) {
        batches.add(current);
        current = <int>[];
        chars = 0;
      }
      current.add(i);
      chars += length;
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  /// One item on its own — the recovery path for a slot the batch lost. Asking
  /// for a single line makes the output cap a non-issue, so a translation that
  /// was merely truncated away comes back.
  Future<String?> _translateOne(
    String input,
    String languageCode,
    double temperature,
    int topK,
    double topP,
  ) async {
    try {
      final result = await _engine.generate(
        _singlePrompt(input, languageCode),
        temperature: temperature,
        topK: topK,
        topP: topP,
      );
      return _firstUsableLine(result.text);
    } catch (_) {
      return null;
    }
  }

  String _singlePrompt(String input, String languageCode) {
    final target = languageCode == 'en' ? 'English' : 'neutral Spanish';
    return 'Translate the following text to $target. Keep any separators or '
        'punctuation inside it. If it is already in $target, return it '
        'unchanged. Answer with the translation only, on a single line, with no '
        'numbering, quotes or commentary.\n\n$input';
  }

  /// The first line of a single-item answer, with any stray `N.` numbering the
  /// model added stripped off. Null when nothing usable came back.
  static String? _firstUsableLine(String out) {
    for (final raw in out.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final numbered = RegExp(r'^\s*\d+[.)]\s*(.*)$').firstMatch(line);
      final text = (numbered == null ? line : numbered.group(1)!).trim();
      if (text.isEmpty) continue;
      return text;
    }
    return null;
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
