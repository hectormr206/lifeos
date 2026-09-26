// Lining up the sounds a sentence should have with the sounds the phone model
// heard, word by word.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/pron_alignment.dart';
import 'package:lifeos/features/english/domain/pron_lexicon.dart';

final _lexicon = PronLexicon.parse([
  'the DH AH0|DH AH1|DH IY0',
  'ship SH IH1 P',
  'either IY1 DH ER0|AY1 DH ER0',
  'worked W ER1 K T',
  'speak S P IY1 K',
  'water W AO1 T ER0',
  'magi M EY1 JH AY0',
  'think TH IH1 NG K',
  'very V EH1 R IY0',
  'and AH0 N D|AE1 N D',
  'her HH ER1|HH ER0',
  'cat K AE1 T',
  'at AE1 T',
  'was W AA1 Z|W AH0 Z',
  'still S T IH1 L',
  'costs K AA1 S T S',
  'today T AH0 D EY1',
].join('\n'));

PronunciationCheck _check(String target, String heard) =>
    checkPronunciation(target: target, heardIpa: heard, lexicon: _lexicon);

List<String> _wrong(PronunciationCheck check) => [
      for (final w in check.words)
        for (final p in w.phones)
          if (!p.ok) '${w.text}:${p.phone.ipa}>${p.heard}',
    ];

void main() {
  test('a sentence said as written has nothing wrong', () {
    final check = _check('The ship', 'ðəʃɪp');

    expect(_wrong(check), isEmpty);
    expect(check.words.map((w) => w.text), ['The', 'ship']);
    expect(check.words.every((w) => w.judged), isTrue);
  });

  test('a vowel said as another is caught, with what was heard', () {
    expect(_wrong(_check('The ship', 'ðəʃip')), ['ship:ɪ>i']);
  });

  test('th said as t is caught', () {
    expect(_wrong(_check('think', 'tɪŋk')), ['think:θ>t']);
  });

  test('a dropped final sound is caught as heard nothing', () {
    expect(_wrong(_check('cat', 'kæ')), ['cat:t>']);
  });

  test('a final t or d after a consonant is not judged when missing', () {
    // Natives often leave it unreleased and the phone model cannot hear the
    // difference, so "worked" said as "work" cannot be told apart. Saying
    // so is better than accusing natives.
    expect(_wrong(_check('worked', 'wə˞k')), isEmpty);
  });

  test('flapped t, and a dark l at the end, are native', () {
    expect(_wrong(_check('cat', 'kæd')), isEmpty, reason: 'final t, flapped');
    expect(_wrong(_check('still', 'stɪʊ')), isEmpty);
    // A t voiced at the start of a word is not a flap.
    expect(_wrong(_check('today', 'dədeɪ')), ['today:t>d']);
  });

  test('an e before s-plus-consonant belongs to the s', () {
    expect(_wrong(_check('speak', 'ɛspik')), ['speak:s>ɛs']);
  });

  test('the variant that fits is the one judged', () {
    expect(_wrong(_check('either', 'aɪðə˞')), isEmpty);
    expect(_wrong(_check('either', 'iðə˞')), isEmpty);
  });

  test('ordinary native variation is not an error', () {
    // cot-caught merger and the flapped t.
    expect(_wrong(_check('water', 'wɑɾə˞')), isEmpty);
    // A monophthong for the diphthong.
    expect(_wrong(_check('magi', 'medʒaɪ')), isEmpty);
    // Unstressed vowels reduce freely.
    expect(_wrong(_check('the', 'ðɪ')), isEmpty);
    // r-colouring written as a plain r.
    expect(_wrong(_check('very', 'vɛɹi')), isEmpty);
    expect(_wrong(_check('water', 'wɔtəɹ')), isEmpty);
  });

  test('a word the lexicon does not know takes its own sounds, unjudged',
      () {
    final check = _check('The Mayjoy ship', 'ðəmeɪdʒɔɪʃɪp');

    expect(_wrong(check), isEmpty);
    expect(check.words[1].judged, isFalse);
    expect(check.words[1].phones, isEmpty);
  });

  test('numbers take their own sounds, unjudged, like unknown words', () {
    // Whisper writes "$1.87"; the phone model hears "one dollar eighty-seven".
    final check = _check(r'It costs $1.87 today', 'kɑstswʌndɑlə˞eɪtisɛvəntədeɪ');

    expect(_wrong(check), isEmpty);
    expect(check.words.map((w) => w.text), ['It', 'costs', r'$1.87', 'today']);
    expect(check.words[2].judged, isFalse);
  });

  test('function words may lose sounds and voicing, as they do in speech', () {
    expect(_wrong(_check('cat and ship', 'kætənʃɪp')), isEmpty);
    expect(_wrong(_check('her ship', 'ə˞ʃɪp')), isEmpty);
    // But a content word may not.
    expect(_wrong(_check('cat', 'kæ')), ['cat:t>']);
  });

  test('a sound carried over from the end of the last word is not extra',
      () {
    expect(_wrong(_check('was still', 'wəzzstɪl')), isEmpty);
    expect(_wrong(_check('at the ship', 'ætðəʃɪp')), isEmpty);
    expect(_wrong(_check('cat', 'kkæt')), isEmpty, reason: 'a doubled sound');
    // A different consonant before a word still counts.
    expect(_wrong(_check('ship', 'tʃɪp')), ['ship:ʃ>tʃ']);
  });

  test('nothing heard at all: every sound of a content word is missing', () {
    final check = _check('The ship', '');

    // A function word may vanish in speech; missing words as such are the
    // intelligibility check's job (Whisper), not this one's.
    expect(_wrong(check), ['ship:ʃ>', 'ship:ɪ>', 'ship:p>']);
  });
}
