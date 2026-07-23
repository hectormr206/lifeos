import 'package:intl/intl.dart';

/// Builds the concise system preamble prepended to every on-device Axi turn
/// (i18n + "Axi knows now" slices).
///
/// Two responsibilities, both minimal so they never disturb the tuned sampling
/// or the FIFO queue:
///   1. LANGUAGE: a one-line instruction so Axi always replies in the selected
///      language ("Responde SIEMPRE en español." / "Always respond in English.").
///   2. CURRENT DATE/TIME: the device-local now, localized to the same locale,
///      so Axi can reason about "today"/"now".
///
/// The [now] is passed in (never read here) so the caller supplies it via the
/// `Clock` seam — the future timezone slice overrides that clock alone.
///
/// Adding a language = one more case in [_languageLine]; the datetime line is
/// already locale-driven.
String buildAxiPromptPreamble({required String languageCode, required DateTime now}) {
  final dateTimeText = formatPromptDateTime(languageCode: languageCode, now: now);
  return '${_languageLine(languageCode)}\n'
      '${_dateTimeLine(languageCode)}: $dateTimeText.';
}

/// Prepends the preamble to a user [message] (blank line between), the exact
/// text handed to the engine's `generate` / `generateWithImages`.
String withAxiPromptPreamble({
  required String message,
  required String languageCode,
  required DateTime now,
}) =>
    '${buildAxiPromptPreamble(languageCode: languageCode, now: now)}\n\n$message';

/// Locale-aware, human-readable formatting of [now] (e.g.
/// "martes, 22 de julio de 2026, 14:30"). Falls back to the raw ISO string if
/// the locale's date symbols were never initialized (keeps it crash-proof in a
/// bare unit test that forgot `initializeDateFormatting`).
String formatPromptDateTime({required String languageCode, required DateTime now}) {
  try {
    final date = DateFormat.yMMMMEEEEd(languageCode).format(now);
    final time = DateFormat.Hm(languageCode).format(now);
    return '$date, $time';
  } catch (_) {
    return now.toIso8601String();
  }
}

String _languageLine(String languageCode) => switch (languageCode) {
      'en' => 'Always respond in English.',
      _ => 'Responde SIEMPRE en español.',
    };

String _dateTimeLine(String languageCode) => switch (languageCode) {
      'en' => 'Current date and time',
      _ => 'Fecha y hora actual',
    };
