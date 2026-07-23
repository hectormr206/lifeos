// Proves Axi's on-device prompt preamble (i18n + "Axi knows now" slices)
// injects BOTH the reply-language instruction AND the current date/time.
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lifeos/features/chat/domain/axi_prompt_context.dart';

void main() {
  setUpAll(() async {
    // Locale-aware date formatting needs the symbols initialized (flutter_
    // localizations does this at runtime; a bare unit test must do it here).
    await initializeDateFormatting('es');
    await initializeDateFormatting('en');
  });

  final now = DateTime(2026, 7, 22, 14, 30);

  test('Spanish preamble carries the language instruction and a date string', () {
    final preamble = buildAxiPromptPreamble(languageCode: 'es', now: now);

    expect(preamble, contains('Responde SIEMPRE en español.'));
    expect(preamble, contains('Fecha y hora actual:'));
    // A recognizable piece of the localized date/time (the year + the time).
    expect(preamble, contains('2026'));
    expect(preamble, contains('14:30'));
  });

  test('English preamble carries the English instruction and a date string', () {
    final preamble = buildAxiPromptPreamble(languageCode: 'en', now: now);

    expect(preamble, contains('Always respond in English.'));
    expect(preamble, contains('Current date and time:'));
    expect(preamble, contains('2026'));
    expect(preamble, contains('14:30'));
  });

  test('withAxiPromptPreamble prepends the preamble and keeps the user message', () {
    final decorated = withAxiPromptPreamble(
      message: '¿Qué día es hoy?',
      languageCode: 'es',
      now: now,
    );

    expect(decorated, startsWith('Responde SIEMPRE en español.'));
    expect(decorated, contains('Fecha y hora actual:'));
    expect(decorated, endsWith('¿Qué día es hoy?'));
  });

  test('formatPromptDateTime is locale-aware', () {
    final es = formatPromptDateTime(languageCode: 'es', now: now);
    final en = formatPromptDateTime(languageCode: 'en', now: now);
    // Spanish month name vs English month name — proves the locale is applied.
    expect(es.toLowerCase(), contains('julio'));
    expect(en.toLowerCase(), contains('july'));
  });
}
