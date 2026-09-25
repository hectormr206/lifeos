// Lining up the sounds a sentence should have with the sounds the phone model
// heard, word by word.
//
// The phone model writes one flat string of symbols for the whole recording,
// with no word boundaries. The sentence is known, so its expected sounds are
// known (per word, from the lexicon, every variant). One dynamic programme
// over the whole sentence finds, at once, where each word starts in what was
// heard, which variant of each word was meant, and which symbol went with
// which sound:
//
//   * each word takes a vector "cost so far, having used j heard symbols" and
//     returns the same vector after itself; every variant of the word is run
//     and the cheapest wins, per j;
//   * a word the lexicon does not know (a name, mostly) is a wildcard: it
//     takes any number of heard symbols for free and is not judged, so its
//     sounds are never blamed on its neighbours;
//   * extra heard symbols before a word belong to that word's first sound
//     (an "e" before "speak" is part of how its s was said).
//   * numbers ("$1.87") are wildcards too: Whisper writes digits, the
//     learner says words.
//
// Then each expected sound is judged on what was heard for it, forgiving the
// variation native speakers have among themselves: unstressed vowels reduce
// or vanish, cot/caught merge, t and d flap, diphthongs may be monophthongs,
// r-colouring may be written as a plain r, function words ("and", "her",
// "to") lose sounds and voicing, and a word's last sound carried into the
// next one is not an extra sound. What is left is what a teacher would point
// at. Measured on a native LibriVox chapter before these allowances: 8.9% of
// words flagged, almost all of it from the cases above.
//
// One learner error is deliberately NOT judged: a final t or d after a
// consonant ("worked" said as "work"). Natives leave it unreleased, and the
// phone model cannot hear the difference.
library;

import 'pron_lexicon.dart';

class PhoneResult {
  const PhoneResult({required this.phone, required this.heard, required this.ok});

  final Phone phone;

  /// The symbols heard for this sound, extra ones before it included; empty
  /// when it was not said.
  final String heard;

  final bool ok;
}

class WordSounds {
  const WordSounds({required this.text, required this.judged, required this.phones});

  /// As written in the sentence.
  final String text;

  /// False for words the lexicon does not know: taken, never judged.
  final bool judged;

  final List<PhoneResult> phones;
}

class PronunciationCheck {
  const PronunciationCheck(this.words);
  final List<WordSounds> words;
}

final RegExp _word = RegExp(
  r"\p{L}+(?:['’]\p{L}+)?|\p{Sc}?\p{N}[\p{N}.,:%]*",
  unicode: true,
);

/// Words that are nearly always said in a weak form: "and" as "ən", "her"
/// without its h, "to" with a d. They are judged, leniently.
const Set<String> _functionWords = {
  'a', 'am', 'an', 'and', 'are', 'as', 'at', 'be', 'been', 'but', 'by', 'can',
  'could', 'do', 'does', 'for', 'from', 'had', 'has', 'have', 'he', 'her',
  'him', 'his', 'if', 'in', 'into', 'is', 'it', 'its', 'just', 'me', 'must',
  'my', 'not', 'of', 'on', 'or', 'our', 'she', 'should', 'so', 'some', 'than',
  'that', 'the', 'them', 'then', 'there', 'these', 'they', 'this', 'those',
  'to', 'us', 'was', 'we', 'were', 'what', 'when', 'will', 'with', 'would',
  'you', 'your',
};

const Map<String, String> _voicing = {
  'p': 'b', 'b': 'p', 't': 'd', 'd': 't', 'k': 'g', 'g': 'k', 'f': 'v',
  'v': 'f', 's': 'z', 'z': 's', 'θ': 'ð', 'ð': 'θ', 'ʃ': 'ʒ', 'ʒ': 'ʃ',
};

/// A symbol and its voicing partner: the same place, the same manner.
Set<String> _sameSound(String unit) => {unit, ?_voicing[unit]};

const String _vowelSymbols = 'aeiouyæøœɐɑɒɔɘəɛɜɞɤɨɪɯɵɶʉʊʌʏ';
bool _isVowel(String unit) => _vowelSymbols.contains(unit);

const double _gap = 1;

/// Pairs close enough that the alignment should prefer lining them up.
const Set<String> _near = {
  'tɾ', 'dɾ', 'tʔ', 'ɑɔ', 'ɔɑ', 'ɑɒ', 'ɔɒ', 'ʌə', 'əʌ', '˞ɹ', 'ɹ˞', 'ɹɻ', 'hɦ',
  'wʍ', 'lɭ',
};

class _Unit {
  const _Unit(this.symbol, this.phone);
  final String symbol;
  final int phone;
}

double _substitution(String expected, String heard, {required bool loose}) {
  if (expected == heard) return 0;
  if (_near.contains('$expected$heard')) return 0.3;
  final ev = _isVowel(expected);
  final hv = _isVowel(heard);
  if (ev && hv) return loose ? 0.3 : 1;
  return ev == hv ? 1 : 1.5;
}

/// One variant of one word, aligned from an entry cost vector.
class _Pass {
  _Pass(this.units, this.entry, this.cost);
  final List<_Unit> units;
  final List<double> entry;

  /// cost[i][j]: first i units said with heard symbols up to j.
  final List<List<double>> cost;
}

_Pass _run(List<Phone> phones, List<String> heard, List<double> entry,
    {required bool trailing}) {
  final units = [
    for (var p = 0; p < phones.length; p++)
      for (final u in phones[p].units) _Unit(u, p),
  ];
  final m = heard.length;
  final cost = [
    for (var i = 0; i <= units.length; i++) List.filled(m + 1, double.infinity),
  ];
  for (var j = 0; j <= m; j++) {
    cost[0][j] = j == 0 ? entry[0] : _min(entry[j], cost[0][j - 1] + _gap);
  }
  for (var i = 1; i <= units.length; i++) {
    final unit = units[i - 1];
    final phone = phones[unit.phone];
    final loose = phone.isVowel && !phone.stressed;
    final drop = loose ? 0.5 : _gap;
    for (var j = 0; j <= m; j++) {
      var best = cost[i - 1][j] + drop;
      if (j > 0) {
        best = _min(best, cost[i - 1][j - 1] +
            _substitution(unit.symbol, heard[j - 1], loose: loose));
        // Extra symbols after the last sound: only at the end of the sentence.
        if (i == units.length && trailing) best = _min(best, cost[i][j - 1] + _gap);
      }
      cost[i][j] = best;
    }
  }
  return _Pass(units, entry, cost);
}

double _min(double a, double b) => a < b ? a : b;

PronunciationCheck checkPronunciation({
  required String target,
  required String heardIpa,
  required PronLexicon lexicon,
}) {
  final heard = heardUnits(heardIpa);
  final m = heard.length;
  final words = [for (final match in _word.allMatches(target)) match.group(0)!];

  // Forward: per word, its entry vector and one pass per variant.
  final passes = <List<_Pass>>[];
  final entries = <List<double>>[];
  var entry = List<double>.generate(m + 1, (j) => j == 0 ? 0 : double.infinity);
  for (var w = 0; w < words.length; w++) {
    entries.add(entry);
    final variants = lexicon.lookup(words[w]);
    final exit = List.filled(m + 1, double.infinity);
    if (variants.isEmpty) {
      var running = double.infinity;
      for (var j = 0; j <= m; j++) {
        running = _min(running, entry[j]);
        exit[j] = running;
      }
      passes.add(const []);
    } else {
      final runs = [
        for (final v in variants)
          _run(v, heard, entry, trailing: w == words.length - 1),
      ];
      for (final run in runs) {
        for (var j = 0; j <= m; j++) {
          exit[j] = _min(exit[j], run.cost.last[j]);
        }
      }
      passes.add(runs);
    }
    entry = exit;
  }

  // Backward: pick each word's variant and read off what was heard per sound.
  final said = List<List<_Said>>.filled(words.length, const []);
  var j = m;
  for (var w = words.length - 1; w >= 0; w--) {
    final runs = passes[w];
    if (runs.isEmpty) {
      j = _cheapestEntry(entries[w], j);
      continue;
    }
    var chosen = 0;
    for (var v = 1; v < runs.length; v++) {
      if (runs[v].cost.last[j] < runs[chosen].cost.last[j]) chosen = v;
    }
    final variant = lexicon.lookup(words[w])[chosen];
    final (phones, start) = _trace(runs[chosen], variant, heard, j);
    said[w] = phones;
    j = start;
  }

  // Forward: judge, knowing how the previous word ended.
  final results = <WordSounds>[];
  var carried = <String>{};
  for (var w = 0; w < words.length; w++) {
    final phones = said[w];
    if (phones.isEmpty) {
      results.add(WordSounds(text: words[w], judged: false, phones: const []));
      carried = {};
      continue;
    }
    final function = _functionWords.contains(words[w].toLowerCase());
    results.add(WordSounds(text: words[w], judged: true, phones: [
      for (var p = 0; p < phones.length; p++)
        PhoneResult(
          phone: phones[p].phone,
          heard: '${phones[p].extra}${phones[p].core}',
          ok: _acceptable(
            phones[p].phone,
            phones[p].extra,
            phones[p].core,
            wordInitialCluster:
                p == 0 && phones.length > 1 && !phones[1].phone.isVowel,
            last: p == phones.length - 1,
            afterConsonant: p > 0 && !phones[p - 1].phone.isVowel,
            betweenVowels: p > 0 &&
                p < phones.length - 1 &&
                phones[p - 1].phone.isVowel &&
                phones[p + 1].phone.isVowel,
            functionWord: function,
            carried: p == 0 ? carried : const {},
          ),
        ),
    ]));
    carried = _sameSound(phones.last.phone.units.last);
  }
  return PronunciationCheck(results);
}

/// What was heard for one expected sound: extra symbols before it, and the
/// symbols lined up with it.
class _Said {
  const _Said(this.phone, this.extra, this.core);
  final Phone phone;
  final String extra;
  final String core;
}

/// Where a wildcard word started: the cheapest entry at or before [j]; on a
/// tie the latest, so the unknown word takes no more than it needs.
int _cheapestEntry(List<double> entry, int j) {
  var best = j;
  for (var k = j - 1; k >= 0; k--) {
    if (entry[k] < entry[best] - 1e-9) best = k;
  }
  return best;
}

(List<_Said>, int) _trace(
    _Pass pass, List<Phone> phones, List<String> heard, int end) {
  final core = List.generate(phones.length, (_) => StringBuffer());
  final prefix = List.generate(phones.length, (_) => StringBuffer());
  final cost = pass.cost;
  final units = pass.units;
  var i = units.length;
  var j = end;
  // Collected backwards, then reversed per phone.
  final taken = <(int phone, String symbol, bool isCore)>[];
  while (i > 0) {
    final unit = units[i - 1];
    final phone = phones[unit.phone];
    final loose = phone.isVowel && !phone.stressed;
    final drop = loose ? 0.5 : _gap;
    if (j > 0 &&
        _same(cost[i][j], cost[i - 1][j - 1] +
            _substitution(unit.symbol, heard[j - 1], loose: loose))) {
      taken.add((unit.phone, heard[j - 1], true));
      i--;
      j--;
    } else if (_same(cost[i][j], cost[i - 1][j] + drop)) {
      i--;
    } else {
      // A trailing extra symbol, after the last sound.
      taken.add((unit.phone, heard[j - 1], true));
      j--;
    }
  }
  // Row 0: extra symbols before the first sound, back to where it entered.
  while (j > 0 && !_same(cost[0][j], pass.entry[j])) {
    taken.add((0, heard[j - 1], false));
    j--;
  }
  for (final (phone, symbol, isCore) in taken.reversed) {
    (isCore ? core : prefix)[phone].write(symbol);
  }
  return (
    [
      for (var p = 0; p < phones.length; p++)
        _Said(phones[p], prefix[p].toString(), core[p].toString()),
    ],
    j,
  );
}

bool _same(double a, double b) => (a - b).abs() < 1e-9;

/// Whether what was heard for [phone] is a normal way to say it.
bool _acceptable(
  Phone phone,
  String prefix,
  String core, {
  required bool wordInitialCluster,
  required bool last,
  required bool afterConsonant,
  required bool betweenVowels,
  required bool functionWord,
  required Set<String> carried,
}) {
  if (prefix.isNotEmpty) {
    // A hesitation vowel before a word is not an error, and neither is a
    // consonant that repeats this sound or carries over the last word's
    // final one. An "e" before s-plus-consonant is the learner's.
    final own = _sameSound(phone.units.first);
    for (final unit in prefix.split('')) {
      if (_isVowel(unit)) {
        if (phone.ipa == 's' && wordInitialCluster) return false;
      } else if (!own.contains(unit) && !carried.contains(unit)) {
        return false;
      }
    }
  }
  final ipa = phone.ipa;
  if (core == ipa) return true;
  if (functionWord && (core.isEmpty || _sameSound(ipa).contains(core))) {
    return true;
  }
  // A final t or d after a consonant is often unreleased, and the phone
  // model cannot tell that from a missing one ("worked" / "work"). It is not
  // judged rather than blamed on natives.
  if ((ipa == 't' || ipa == 'd') && last && afterConsonant && core.isEmpty) {
    return true;
  }
  // The flapped t ("let it", "water") is often written as d.
  if (ipa == 't' && core == 'd' && (last || betweenVowels)) return true;
  // A dark l at the end of a word may sound like a vowel ("Dell", "still").
  if (ipa == 'l' && last && (core == 'ʊ' || core == 'o')) return true;
  if (phone.isVowel && !phone.stressed) {
    if (ipa == 'ə˞') return core.isEmpty || _rhotic(core) || _vowelsOnly(core);
    return core.isEmpty || _vowelsOnly(core);
  }
  if (ipa == 'ə˞') return _rhotic(core);
  return _variants[ipa]?.contains(core) ?? false;
}

bool _rhotic(String s) => s.contains('˞') || s.contains('ɹ') || s.contains('ɻ');

bool _vowelsOnly(String s) => s.isNotEmpty && s.split('').every(_isVowel);

/// Native ways of saying a sound, besides the dictionary one.
const Map<String, Set<String>> _variants = {
  'ɑ': {'ɔ', 'ɒ', 'a'},
  'ɔ': {'ɑ', 'ɒ'},
  'ʌ': {'ə'},
  'eɪ': {'e', 'ei'},
  'oʊ': {'o', 'ou', 'əʊ'},
  't': {'ɾ', 'ʔ'},
  'd': {'ɾ'},
  'ɹ': {'ɻ', '˞'},
  'h': {'ɦ'},
  'w': {'ʍ'},
  'l': {'ɭ'},
};
