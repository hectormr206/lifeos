// From "these sounds differed" to the one or two things worth practising.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/pron_alignment.dart';
import 'package:lifeos/features/english/domain/pron_feedback.dart';
import 'package:lifeos/features/english/domain/pron_lexicon.dart';

final _lexicon = PronLexicon.parse([
  'ship SH IH1 P',
  'sit S IH1 T',
  'very V EH1 R IY0',
  'think TH IH1 NG K',
  'speak S P IY1 K',
  'the DH AH0|DH AH1|DH IY0',
  'cat K AE1 T',
  'zoo Z UW1',
  'job JH AA1 B',
  'hello HH AH0 L OW1',
  'red R EH1 D',
  'check CH EH1 K',
  'shop SH AA1 P',
  'book B UH1 K',
  'cup K AH1 P',
  'of AH1 V|AH0 V',
  "i've AY1 V",
  'jim JH IH1 M',
].join('\n'));

List<SoundTip> _tips(String target, String heard) => soundTips(
      checkPronunciation(target: target, heardIpa: heard, lexicon: _lexicon),
    );

void main() {
  test('each typical Spanish-speaker sound is named', () {
    final cases = {
      ('ship', 'ʃip'): SoundPattern.shortI,
      ('cat', 'kat'): SoundPattern.catVowel,
      ('cup', 'kap'): SoundPattern.cupVowel,
      ('cup', 'kup'): SoundPattern.cupVowel,
      ('book', 'buk'): SoundPattern.bookVowel,
      ('very', 'bɛɹi'): SoundPattern.vAsB,
      ('very', 'βɛɹi'): SoundPattern.vAsB,
      ('think', 'tɪŋk'): SoundPattern.thVoiceless,
      ('think', 'sɪŋk'): SoundPattern.thVoiceless,
      ('the', 'də'): SoundPattern.thVoiced,
      ('the', 'tə'): SoundPattern.thVoiced,
      ('speak', 'ɛspik'): SoundPattern.eBeforeS,
      ('speak', 'hɪspik'): SoundPattern.eBeforeS,
      ('zoo', 'su'): SoundPattern.zAsS,
      ('shop', 'tʃɑp'): SoundPattern.shSound,
      ('shop', 'sɑp'): SoundPattern.shSound,
      ('job', 'ʝɑb'): SoundPattern.jSound,
      ('job', 'xɑb'): SoundPattern.jSound,
      // A vowel the alignment carried into the consonant does not hide it.
      ('job', 'jɑɑb'): SoundPattern.jSound,
      ('hello', 'xəloʊ'): SoundPattern.hAsJota,
      ('red', 'rɛd'): SoundPattern.spanishR,
      ('cat', 'kæ'): SoundPattern.finalSound,
    };
    for (final MapEntry(key: (target, heard), value: pattern) in cases.entries) {
      final tips = _tips(target, heard);
      expect(tips.map((t) => t.pattern), [pattern], reason: '$target as $heard');
      expect(tips.single.words, [target]);
    }
  });

  test('function words and contractions only count for th', () {
    // Measured on native speech: weak forms ("of" as "ob", "I've" as "I")
    // gave false tips. "the" said as "de" is the one worth keeping.
    expect(_tips('of', 'ɑb'), isEmpty);
    expect(_tips("I've", 'aɪ'), isEmpty);
    expect(_tips('the', 'də').single.pattern, SoundPattern.thVoiced);
  });

  test('ch said as sh is not a tip: the phone model hears it in natives', () {
    // A native "Check the job" at the start of a sentence came out as ʃɛk.
    expect(_tips('check', 'ʃɛk'), isEmpty);
  });

  test('an American uh heard as ɑ is not a tip', () {
    // A native voice's "cup" came out as kɑp: the two are close.
    expect(_tips('cup', 'kɑp'), isEmpty);
  });

  test('a zh for j is not a tip: the phone model hears it in natives', () {
    expect(_tips('Jim', 'ʒɪm'), isEmpty);
    expect(_tips('Jim', 'ʝɪm').single.pattern, SoundPattern.jSound);
  });

  test('said as written, there is nothing to practise', () {
    expect(_tips('the ship', 'ðəʃɪp'), isEmpty);
  });

  test('a difference that is no known pattern is not shown', () {
    // k heard as g: possible noise, and not a typical Spanish-speaker error.
    expect(_tips('check', 'tʃɛg'), isEmpty);
  });

  test('two tips at most, the most important first, words grouped', () {
    final tips = _tips('ship sit very the zoo', 'ʃip sit bɛɹi də su');

    expect(tips.map((t) => t.pattern), [SoundPattern.shortI, SoundPattern.vAsB]);
    expect(tips.first.words, ['ship', 'sit']);
  });

  test('a tip keeps what was expected and what was heard, for the screen',
      () {
    final tip = _tips('ship', 'ʃip').single;

    expect(tip.expected, 'ɪ');
    expect(tip.heard, 'i');
  });
}
