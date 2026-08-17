// What a real keyboard puts in the field, and what the app must forgive.
//
// This suite exists because confirmation rejected words that were RIGHT. Gboard
// turns a double space into ". ", people separate a list with commas, and a
// wrapped line can leave a soft hyphen (U+00AD) behind — none of which the user
// can see. The measured result before the fix:
//
//     PASA  exacto · mayúscula · espacio final · salto de línea
//     FALLA punto final · coma final · guion suave
//
// Telling someone their correct phrase is wrong is worse than a crash: a crash
// gets reported, this gets believed. The user retypes, fails again, and
// concludes they wrote the words down wrong — then turns sync off.
//
// The tolerance is strictly at the INPUT boundary. `normalisePhrase` keeps its
// exact meaning because the shared Python vectors pin it; what changes is only
// what we accept from a human typing on glass.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/sync/phrase.dart';
import 'package:lifeos/features/sync/domain/phrase_ceremony.dart';

void main() {
  group('confirmation forgives punctuation the keyboard added', () {
    // Every artifact here was produced by a real keyboard, not imagined.
    final artifacts = <String, String Function(String)>{
      'a period from Gboard double-space': (w) => '$w.',
      'a comma, because people write lists': (w) => '$w,',
      'a soft hyphen from a wrapped line': (w) => '$w­',
      'a trailing space': (w) => '$w ',
      'a capital first letter': (w) => w[0].toUpperCase() + w.substring(1),
      'a non-breaking space': (w) => '$w ',
      'quotes around the word': (w) => '"$w"',
    };

    for (final artifact in artifacts.entries) {
      test('accepts ${artifact.key}', () {
        final ceremony = PhraseCeremony.generate();

        final ok = ceremony.confirm({
          for (final i in ceremony.challengeIndices)
            i: artifact.value(ceremony.words[i]),
        });

        expect(ok, isTrue,
            reason: 'the word is correct; only the keyboard differed');
      });
    }

    test('still refuses a genuinely wrong word', () {
      // The tolerance must not become "accepts anything". A different word is
      // still a different word, however it is punctuated.
      final ceremony = PhraseCeremony.generate();
      final wrong = ceremony.words[ceremony.challengeIndices.first] == 'zoo'
          ? 'abandon'
          : 'zoo';

      final ok = ceremony.confirm({
        for (final i in ceremony.challengeIndices) i: '$wrong.',
      });

      expect(ok, isFalse);
    });

    test('does not let punctuation alone stand in for a word', () {
      final ceremony = PhraseCeremony.generate();

      final ok = ceremony.confirm({
        for (final i in ceremony.challengeIndices) i: '.',
      });

      expect(ok, isFalse);
    });
  });

  group('a typed phrase survives the same treatment', () {
    // The join path has the identical failure mode, and worse consequences:
    // the second device tells the user their real phrase is invalid.
    test('commas between words do not invalidate a good phrase', () {
      final ceremony = PhraseCeremony.generate();

      expect(
        decodePhrase(sanitiseTypedPhrase(ceremony.words.join(', '))),
        ceremony.entropy,
      );
    });

    test('a trailing period does not invalidate a good phrase', () {
      final ceremony = PhraseCeremony.generate();

      expect(
        decodePhrase(sanitiseTypedPhrase('${ceremony.mnemonic}.')),
        ceremony.entropy,
      );
    });

    test('words glued by a comma are separated, not merged', () {
      // "abandon,ability" must become two words. Deleting the comma instead of
      // replacing it would produce "abandonability" — one invalid word, and a
      // phrase rejected for a reason the user cannot see.
      final ceremony = PhraseCeremony.generate();

      expect(
        decodePhrase(sanitiseTypedPhrase(ceremony.words.join(','))),
        ceremony.entropy,
      );
    });

    test('a wrong phrase is still wrong after sanitising', () {
      expect(
        () => decodePhrase(
          sanitiseTypedPhrase(List.filled(kWordCount, 'abandon').join(', ')),
        ),
        throwsA(isA<InvalidPhrase>()),
      );
    });

    test('sanitising leaves an already-clean phrase untouched', () {
      final ceremony = PhraseCeremony.generate();

      expect(sanitiseTypedPhrase(ceremony.mnemonic), ceremony.mnemonic);
    });
  });
}
