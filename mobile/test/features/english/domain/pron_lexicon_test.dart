// What a word should sound like, and what the phone model heard.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/pron_lexicon.dart';

void main() {
  group('arpabetToPhones', () {
    test('turns CMUdict ARPAbet into the IPA the phone model writes', () {
      expect(arpabetToPhones('SH IH1 P').map((p) => p.ipa), ['ʃ', 'ɪ', 'p']);
      expect(arpabetToPhones('M EY1 JH AY0').map((p) => p.ipa),
          ['m', 'eɪ', 'dʒ', 'aɪ']);
      expect(arpabetToPhones('R IY1 CH').map((p) => p.ipa), ['ɹ', 'i', 'tʃ']);
    });

    test('schwa and the stressed "uh" are told apart', () {
      expect(arpabetToPhones('DH AH0').map((p) => p.ipa), ['ð', 'ə']);
      expect(arpabetToPhones('K AH1 T').map((p) => p.ipa), ['k', 'ʌ', 't']);
    });

    test('r-coloured vowels are schwa plus the hook, stressed or not', () {
      expect(arpabetToPhones('W ER1 K T').map((p) => p.ipa),
          ['w', 'ə˞', 'k', 't']);
      expect(arpabetToPhones('W AO1 T ER0').last.ipa, 'ə˞');
    });

    test('stress is kept: only vowels carry it', () {
      final phones = arpabetToPhones('V EH1 R IY0');
      expect([for (final p in phones) p.stressed], [false, true, false, false]);
      expect(phones.first.isVowel, isFalse);
      expect(phones[1].isVowel, isTrue);
    });

    test('an unknown symbol is an error, not a silent gap', () {
      expect(() => arpabetToPhones('SH XX1 P'), throwsFormatException);
    });
  });

  group('PronLexicon', () {
    const text = 'either IY1 DH ER0|AY1 DH ER0\n'
        'ship SH IH1 P\n'
        "isn't IH1 Z AH0 N T\n";

    test('every variant of a word is kept', () {
      final lexicon = PronLexicon.parse(text);
      final either = lexicon.lookup('either');
      expect(either, hasLength(2));
      expect(either.last.first.ipa, 'aɪ');
    });

    test('lookup forgives case and curly apostrophes', () {
      final lexicon = PronLexicon.parse(text);
      expect(lexicon.lookup('Ship'), hasLength(1));
      expect(lexicon.lookup('Isn’t'), hasLength(1));
    });

    test('a word it does not know gives nothing', () {
      expect(PronLexicon.parse(text).lookup('Mayjoy'), isEmpty);
    });
  });

  group('heardUnits', () {
    test('the phone model output becomes one unit per sound symbol', () {
      expect(heardUnits('ðəgɪft'), ['ð', 'ə', 'g', 'ɪ', 'f', 't']);
    });

    test('length, aspiration and nasal marks are dropped', () {
      expect(heardUnits('pʰiːs'), ['p', 'i', 's']);
      // The model writes nasalisation as a separate combining tilde.
      expect(heardUnits('e\u0303'), ['e']);
    });

    test('the rhotic hook stays, and the open-mid central vowel reads as schwa',
        () {
      expect(heardUnits('wɜ˞k'), ['w', 'ə', '˞', 'k']);
    });

    test('word boundary marks and spaces are ignored', () {
      expect(heardUnits('ʃɪp ▁ ɪz'), ['ʃ', 'ɪ', 'p', 'ɪ', 'z']);
    });
  });

  test('a phone splits into the same units the model writes', () {
    expect(arpabetToPhones('EY1').single.units, ['e', 'ɪ']);
    expect(arpabetToPhones('ER0').single.units, ['ə', '˞']);
    expect(arpabetToPhones('JH').single.units, ['d', 'ʒ']);
  });
}
