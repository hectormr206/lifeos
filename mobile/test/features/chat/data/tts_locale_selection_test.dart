// Proves the TTS gateway's locale selection (i18n slice): the candidate list
// per language and the "first available wins, else engine default" rule.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/data/flutter_tts_text_to_speech_gateway.dart';

void main() {
  group('ttsLocaleCandidates', () {
    test('Spanish prefers neutral Latin-American, then Spain, then bare tag', () {
      expect(ttsLocaleCandidates('es'), ['es-MX', 'es-ES', 'es']);
    });

    test('English prefers US, then GB, then bare tag', () {
      expect(ttsLocaleCandidates('en'), ['en-US', 'en-GB', 'en']);
    });

    test('an unknown language falls back to its bare tag', () {
      expect(ttsLocaleCandidates('fr'), ['fr']);
    });
  });

  group('firstAvailableTtsLocale', () {
    test('picks the first candidate the engine reports as available', () async {
      final chosen = await firstAvailableTtsLocale(
        ttsLocaleCandidates('es'),
        (locale) async => locale == 'es-ES', // es-MX missing, es-ES present
      );
      expect(chosen, 'es-ES');
    });

    test('returns the highest-priority available English locale', () async {
      final chosen = await firstAvailableTtsLocale(
        ttsLocaleCandidates('en'),
        (locale) async => true, // everything available → first candidate wins
      );
      expect(chosen, 'en-US');
    });

    test('returns null when no candidate is available (engine keeps default)', () async {
      final chosen = await firstAvailableTtsLocale(
        ttsLocaleCandidates('es'),
        (locale) async => false,
      );
      expect(chosen, isNull);
    });

    test('a throwing probe is treated as unavailable and skipped', () async {
      final chosen = await firstAvailableTtsLocale(
        ttsLocaleCandidates('en'),
        (locale) async {
          if (locale == 'en-US') throw Exception('engine hiccup');
          return locale == 'en-GB';
        },
      );
      expect(chosen, 'en-GB');
    });
  });
}
