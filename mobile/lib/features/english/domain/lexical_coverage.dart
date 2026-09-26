// How much of a text the learner already knows.
//
// Reading only teaches when almost every word is already known. Hu & Nation
// (2000) found adequate unassisted comprehension needs about 98% of the running
// words; around 95% is the floor even with help such as glosses. Below that,
// a text is a dictionary exercise, and that is exactly the kind of session
// that makes people quit. So every text is measured against the learner's own
// placement BEFORE it is offered.
//
// The measure is deterministic and needs no model: each word is brought back
// to its dictionary form, looked up in the word bank, and counted as known
// with the probability the placement gave its band. Names and numbers are not
// vocabulary and are left out.
//
// Limits, stated so nobody mistakes this for more than it is: the lemmatizer is
// a set of English suffix rules plus the common irregular forms, not a morph
// analyzer; and any word the bank does not have counts as unknown. Both err on
// the side of calling a text harder than it is, which is the safe side.
library;

import 'vocab_placement_session.dart';

/// Hu & Nation (2000): comprehension without help.
const double kEasyCoverage = 0.98;

/// Hu & Nation (2000): the floor for learning from a text with help.
const double kAtLevelCoverage = 0.95;

/// Below this probability a word is listed as unknown.
const double _unknownBelow = 0.5;

enum TextFit {
  /// 98% or more: reading for fluency.
  easy,

  /// 95-98%: new words can be learned from context and glosses.
  atLevel,

  /// Under 95%: too many gaps to learn from.
  hard,

  /// No words to measure.
  empty,
}

TextFit fitFor(double coverage) {
  if (coverage >= kEasyCoverage) return TextFit.easy;
  if (coverage >= kAtLevelCoverage) return TextFit.atLevel;
  return TextFit.hard;
}

/// The word bank, searchable by any form of a word.
class WordIndex {
  WordIndex(VocabBank bank)
      : _bandOf = {
          for (var band = bank.bands.length - 1; band >= 0; band--)
            for (final word in bank.bands[band]) word: band,
        };

  final Map<String, int> _bandOf;

  /// The frequency band of [lemma] (0 = most frequent), or null.
  int? bandOf(String lemma) =>
      _bandOf[lemma] ?? (_oneLetterWords.contains(lemma) ? 0 : null);

  /// The bank word behind [form], or null when the bank does not have it.
  ///
  /// British spellings are tried only after the word as written, so "four" is
  /// never read as "for".
  String? lemmaOf(String form) {
    final word = form.toLowerCase();
    if (_oneLetterWords.contains(word)) return word;
    for (final spelling in {word, _americanized(word)}) {
      final lemma = _lookup(spelling);
      if (lemma != null) return lemma;
    }
    return null;
  }

  String? _lookup(String word) {
    if (_bandOf.containsKey(word)) return word;
    final irregular = _irregular[word];
    if (irregular != null && _bandOf.containsKey(irregular)) return irregular;
    for (final candidate in _candidates(word)) {
      if (_bandOf.containsKey(candidate)) return candidate;
    }
    return null;
  }
}

/// The bank has no one-letter words: "a" and "i" would be silly test items.
/// They are also the most frequent words there are, so they count as band 0.
const Set<String> _oneLetterWords = {'a', 'i'};

/// The bank keeps American spellings; British ones are common in real texts.
String _americanized(String word) {
  var out = word
      .replaceAll('our', 'or')
      .replaceAll('isation', 'ization')
      .replaceAll('yse', 'yze');
  if (out.endsWith('ise')) out = '${out.substring(0, out.length - 3)}ize';
  if (out.endsWith('re') && out.length > 4) {
    out = '${out.substring(0, out.length - 2)}er';
  }
  return out;
}

/// Dictionary forms a regular inflection may come from, most likely first.
Iterable<String> _candidates(String word) sync* {
  String cut(int n) => word.substring(0, word.length - n);
  bool doubled(String stem) =>
      stem.length > 2 && stem[stem.length - 1] == stem[stem.length - 2];

  if (word.endsWith('ies') && word.length > 4) yield '${cut(3)}y';
  if (word.endsWith('ves') && word.length > 4) {
    yield '${cut(3)}f';
    yield '${cut(3)}fe';
  }
  if (word.endsWith('es')) yield cut(2);
  if (word.endsWith('s') && !word.endsWith('ss')) yield cut(1);
  for (final suffix in const ['ed', 'ing', 'er', 'est']) {
    // A stem of two letters is real: going, doing, using, being.
    if (!word.endsWith(suffix) || word.length < suffix.length + 2) continue;
    final stem = cut(suffix.length);
    yield stem;
    yield '${stem}e';
    if (doubled(stem)) yield stem.substring(0, stem.length - 1);
    if (stem.endsWith('i')) yield '${stem.substring(0, stem.length - 1)}y';
  }
  if (word.endsWith('d')) yield cut(1);
}

const Map<String, String> _irregular = {
  'am': 'be', 'is': 'be', 'are': 'be', 'was': 'be', 'were': 'be',
  'been': 'be', 'has': 'have', 'had': 'have', 'does': 'do', 'did': 'do',
  'done': 'do', 'went': 'go', 'gone': 'go', 'said': 'say', 'made': 'make',
  'took': 'take', 'taken': 'take', 'came': 'come', 'saw': 'see',
  'seen': 'see', 'got': 'get', 'gotten': 'get', 'knew': 'know',
  'known': 'know', 'thought': 'think', 'told': 'tell', 'found': 'find',
  'gave': 'give', 'given': 'give', 'left': 'leave', 'felt': 'feel',
  'brought': 'bring', 'began': 'begin', 'begun': 'begin', 'kept': 'keep',
  'held': 'hold', 'wrote': 'write', 'written': 'write', 'stood': 'stand',
  'heard': 'hear', 'meant': 'mean', 'met': 'meet', 'ran': 'run',
  'paid': 'pay', 'sat': 'sit', 'spoke': 'speak', 'spoken': 'speak',
  'led': 'lead', 'grew': 'grow', 'grown': 'grow', 'lost': 'lose',
  'fell': 'fall', 'fallen': 'fall', 'sent': 'send', 'built': 'build',
  'understood': 'understand', 'drew': 'draw', 'drawn': 'draw',
  'broke': 'break', 'broken': 'break', 'spent': 'spend', 'rose': 'rise',
  'risen': 'rise', 'drove': 'drive', 'driven': 'drive', 'bought': 'buy',
  'wore': 'wear', 'worn': 'wear', 'chose': 'choose', 'chosen': 'choose',
  'ate': 'eat', 'eaten': 'eat', 'forgot': 'forget', 'forgotten': 'forget',
  'hid': 'hide', 'hidden': 'hide', 'shown': 'show', 'threw': 'throw',
  'thrown': 'throw', 'flew': 'fly', 'flown': 'fly', 'swam': 'swim',
  'sang': 'sing', 'sung': 'sing', 'won': 'win', 'caught': 'catch',
  'taught': 'teach', 'fought': 'fight', 'sold': 'sell', 'slept': 'sleep',
  'woke': 'wake', 'children': 'child', 'men': 'man', 'women': 'woman',
  'feet': 'foot', 'teeth': 'tooth', 'mice': 'mouse', 'better': 'good',
  'best': 'good', 'worse': 'bad', 'worst': 'bad', 'became': 'become',
  'beaten': 'beat', 'bred': 'breed', 'fed': 'feed', 'hung': 'hang',
  'shot': 'shoot', 'struck': 'strike', 'stuck': 'stick', 'lent': 'lend',
  'bent': 'bend', 'dealt': 'deal', 'dug': 'dig', 'fled': 'flee',
  'forbade': 'forbid', 'froze': 'freeze', 'frozen': 'freeze', 'ground': 'grind',
  'laid': 'lay', 'lain': 'lie', 'lit': 'light', 'rode': 'ride', 'ridden': 'ride',
  'rang': 'ring', 'rung': 'ring', 'sought': 'seek', 'shook': 'shake',
  'shaken': 'shake', 'shone': 'shine', 'sank': 'sink', 'sunk': 'sink',
  'slid': 'slide', 'stole': 'steal', 'stolen': 'steal', 'swore': 'swear',
  'sworn': 'swear', 'tore': 'tear', 'torn': 'tear', 'wept': 'weep',
  'wound': 'wind', 'withdrew': 'withdraw', 'withdrawn': 'withdraw',
};

/// Contractions, read as the words they stand for. A possessive or "is" 's is
/// dropped: either way the word it hangs on is what has to be known.
List<String> _expand(String token) {
  final lower = token.toLowerCase();
  const special = {
    "won't": ['will', 'not'],
    "can't": ['can', 'not'],
    'cannot': ['can', 'not'],
  };
  final whole = special[lower];
  if (whole != null) return whole;
  const endings = {
    "n't": 'not', "'re": 'are', "'ll": 'will', "'ve": 'have', "'d": 'would',
    "'m": 'am', "'s": '',
  };
  for (final entry in endings.entries) {
    if (lower.endsWith(entry.key) && lower.length > entry.key.length) {
      final base = lower.substring(0, lower.length - entry.key.length);
      return [base, if (entry.value.isNotEmpty) entry.value];
    }
  }
  return [lower];
}

final RegExp _word = RegExp(r"\p{L}+(?:'\p{L}+)?", unicode: true);
/// A full stop ends a sentence only when a space or the end follows it: the
/// point in "$0.10/M" does not, or "M" would read as a sentence start.
final RegExp _sentenceEnd = RegExp(r'[.!?](?=\s|$)|\n');
final RegExp _digit = RegExp(r'[0-9]');

/// Units written after a number ("5 km"). "in" is left out: it is a word.
const Set<String> _units = {
  'km', 'm', 'cm', 'mm', 'kg', 'g', 'mg', 'ft', 'mi', 'lb', 'lbs', 'oz',
  'mph', 'kph', 'ml', 'l', 'h', 'hr', 'hrs', 'sec', 's', 'kb', 'mb', 'gb',
  'tb', 'px',
};

/// True when the first non-space character before [start] is a digit.
bool _afterNumber(String text, int start) {
  for (var i = start - 1; i >= 0; i--) {
    final c = text[i];
    if (c == ' ') continue;
    return _digit.hasMatch(c);
  }
  return false;
}

/// The words of [text] that count as vocabulary, lowercased, in order.
///
/// A capitalized word in mid-sentence is a name (Maria, Paris, GitHub) and is
/// left out: nobody has to "know" a name to read it. At the start of a
/// sentence a capital means nothing, so that word is kept. "I" is always a
/// capital and never a name. Letters glued to a number (20th, 5km, 1990s) are
/// a unit or an ordinal, not a word.
List<String> contentWords(String text) {
  final normalized = text.replaceAll('\u2019', "'");
  final words = <String>[];
  var sentenceStart = true;
  var previousEnd = 0;
  for (final match in _word.allMatches(normalized)) {
    final gap = normalized.substring(previousEnd, match.start);
    if (_sentenceEnd.hasMatch(gap)) sentenceStart = true;
    previousEnd = match.end;

    final token = match.group(0)!;
    final before = match.start > 0 ? normalized[match.start - 1] : '';
    final after = match.end < normalized.length ? normalized[match.end] : '';
    if (_digit.hasMatch(before) || _digit.hasMatch(after)) continue;

    final lower = token.toLowerCase();
    if (_units.contains(lower) && _afterNumber(normalized, match.start)) {
      continue;
    }
    final isI = lower == 'i' || lower.startsWith("i'");
    final capitalized = token[0] != token[0].toLowerCase();
    if (capitalized && !sentenceStart && !isI) continue;
    sentenceStart = false;
    words.addAll(_expand(token));
  }
  return words;
}

class CoverageReport {
  const CoverageReport({
    required this.words,
    required this.coverage,
    required this.unknownLemmas,
  });

  /// Vocabulary words counted (names and numbers excluded).
  final int words;

  /// Expected share of [words] the learner knows, 0-1.
  final double coverage;

  /// Words likely unknown, most repeated first: the ones worth learning.
  final List<String> unknownLemmas;

  TextFit get fit => words == 0 ? TextFit.empty : fitFor(coverage);
}

/// Measures [text] against a placement's per-band known shares.
CoverageReport measureCoverage(
  String text,
  WordIndex index, {
  required List<double> knownByBand,
}) {
  final words = contentWords(text);
  if (words.isEmpty) {
    return const CoverageReport(words: 0, coverage: 0, unknownLemmas: []);
  }

  var known = 0.0;
  final unknownCounts = <String, int>{};
  for (final word in words) {
    final lemma = index.lemmaOf(word);
    final band = lemma == null ? null : index.bandOf(lemma);
    final p = band != null && band < knownByBand.length ? knownByBand[band] : 0.0;
    known += p;
    if (p < _unknownBelow) {
      final key = lemma ?? word;
      unknownCounts[key] = (unknownCounts[key] ?? 0) + 1;
    }
  }

  final unknown = unknownCounts.keys.toList()
    ..sort((a, b) => unknownCounts[b]!.compareTo(unknownCounts[a]!));
  return CoverageReport(
    words: words.length,
    coverage: known / words.length,
    unknownLemmas: unknown,
  );
}
