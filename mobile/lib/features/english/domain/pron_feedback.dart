// From "these sounds differed" to the one or two things worth practising.
//
// The alignment marks every sound that differed; this keeps only the
// differences that are a known Spanish-speaker pattern (ship/sheep, v as b,
// th as t, "espeak"…), because those are both the likely true ones (the
// phone model has its own noise, which lands anywhere) and the ones a
// specific tip helps with. At most two per sentence, the ones that cost
// understanding most first, as the writing feedback does: more is noise to a
// learner.
//
// Function words and contractions give only the th tip ("the" as "de", the
// one that matters): on a native LibriVox chapter their weak forms were
// most of the false tips. On that chapter 7 of 61 thirteen-second chunks got
// a tip before this rule and dropping ʒ from the j pattern (natives' J is
// heard as ʒ by the phone model).
//
// Checked on the other side with Piper voices: an English voice saying the
// errors on purpose ("I tink this sheep", "the cot has a red cop") and a
// Mexican Spanish voice reading English with Spanish phonetics. ch said as sh
// is left out: the phone model heard a native "Check…" at the start of a
// sentence as "sheck".
library;

import 'pron_alignment.dart';

/// Declared in priority order: earlier ones cost understanding more.
enum SoundPattern {
  /// ɪ said as i: "ship" heard as "sheep", "sit" as "seat".
  shortI,

  /// æ said as a Spanish a or e: "cat", "bad".
  catVowel,

  /// v said as b: "very" heard as "berry".
  vAsB,

  /// θ said as t, s or f: "think" heard as "tink" or "sink".
  thVoiceless,

  /// An e before s-plus-consonant: "speak" as "espeak".
  eBeforeS,

  /// z said as s: "zoo" as "sue", "please" with an s.
  zAsS,

  /// ð said as d or t: "the" as "de" or "te".
  thVoiced,

  /// ʌ said as a Spanish a, o or u: "cup" read as written.
  cupVowel,

  /// ʊ said as u: "book" as "boohk".
  bookVowel,

  /// ʃ said as tʃ or s: "shop" as "chop" or "sop".
  shSound,

  /// dʒ said as a Spanish y or j: "job" as "yob" or with a jota.
  jSound,

  /// h said as a Spanish j: "hello" with a jota.
  hAsJota,

  /// A final consonant left out: "cat" as "ca".
  finalSound,

  /// A Spanish r, tapped or trilled.
  spanishR,
}

class SoundTip {
  const SoundTip({
    required this.pattern,
    required this.words,
    required this.expected,
    required this.heard,
  });

  final SoundPattern pattern;

  /// The words where it happened, as written, each once.
  final List<String> words;

  /// The first occurrence: the sound expected and what was heard, in IPA.
  final String expected;
  final String heard;
}

/// At most this many tips per sentence.
const int kMaxSoundTips = 2;

const String _vowels = 'aeiouæɐɑɒɔəɛɪʊʌ';

SoundPattern? _pattern(PhoneResult result, {required bool last}) {
  final e = result.phone.ipa;
  final h = result.heard;
  if (e == 's' && RegExp('[$_vowels]s\$').hasMatch(h)) {
    return SoundPattern.eBeforeS;
  }
  if (!result.phone.isVowel && last && h.isEmpty) return SoundPattern.finalSound;
  // For a consonant, vowels the alignment carried in do not hide what it was.
  final said = result.phone.isVowel ? h : h.replaceAll(RegExp('[$_vowels]'), '');
  return switch ((e, said)) {
    ('ɪ', 'i') when result.phone.stressed => SoundPattern.shortI,
    ('æ', 'a' || 'ɑ' || 'ɛ' || 'e' || 'ɐ') => SoundPattern.catVowel,
    // Not ɑ: an American ʌ is close to it, and a native "cup" was heard so.
    ('ʌ', 'a' || 'u' || 'o' || 'ɔ') => SoundPattern.cupVowel,
    ('ʊ', 'u') => SoundPattern.bookVowel,
    ('v', 'b' || 'β') => SoundPattern.vAsB,
    ('θ', 't' || 's' || 'f') => SoundPattern.thVoiceless,
    ('ð', 'd' || 't') => SoundPattern.thVoiced,
    ('z', 's') => SoundPattern.zAsS,
    ('ʃ', 'tʃ' || 's') => SoundPattern.shSound,
    ('dʒ', 'j' || 'ʝ' || 'ɟʝ' || 'dʝ' || 'ɟ' || 'x' || 'χ') => SoundPattern.jSound,
    ('h', 'x' || 'χ' || 'ç') => SoundPattern.hAsJota,
    ('ɹ', 'r' || 'ɾ') => SoundPattern.spanishR,
    _ => null,
  };
}

List<SoundTip> soundTips(PronunciationCheck check) {
  final found = <SoundPattern, (List<String>, PhoneResult)>{};
  for (final word in check.words) {
    for (var p = 0; p < word.phones.length; p++) {
      final result = word.phones[p];
      if (result.ok) continue;
      final pattern = _pattern(result, last: p == word.phones.length - 1);
      if (pattern == null) continue;
      if (word.weak && pattern != SoundPattern.thVoiced) continue;
      final (words, _) = found.putIfAbsent(pattern, () => (<String>[], result));
      if (!words.contains(word.text)) words.add(word.text);
    }
  }
  final patterns = found.keys.toList()..sort((a, b) => a.index - b.index);
  return [
    for (final pattern in patterns.take(kMaxSoundTips))
      SoundTip(
        pattern: pattern,
        words: found[pattern]!.$1,
        expected: found[pattern]!.$2.phone.ipa,
        heard: found[pattern]!.$2.heard,
      ),
  ];
}

/// Share of expected sounds that must have been heard as something (right or
/// wrong) for the recording to count as the sentence said.
const double kMinHeardShare = 0.6;

/// Whether the sentence was actually said: an accent changes sounds but they
/// are heard; silence or room noise leaves nearly all of them missing, and
/// then "the final sound was not heard" is not a tip, it is an artefact (seen
/// on the Pixel with a recording of noise). Function words do not count:
/// dropping them is normal speech.
bool heardEnough(PronunciationCheck check) {
  var expected = 0;
  var heard = 0;
  for (final word in check.words) {
    if (!word.judged || word.weak) continue;
    for (final phone in word.phones) {
      expected++;
      if (phone.heard.isNotEmpty) heard++;
    }
  }
  return expected > 0 && heard / expected >= kMinHeardShare;
}
