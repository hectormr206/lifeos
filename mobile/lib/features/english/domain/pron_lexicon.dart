// What a word should sound like, and what the phone model heard.
//
// Expected sounds come from CMUdict (American English, ARPAbet), turned into
// the IPA that ZIPA, the phone recogniser, writes: `ɹ` for English r, `ə˞`
// for the r-coloured vowel, `eɪ`/`oʊ`/`aɪ` diphthongs, `tʃ`/`dʒ` affricates.
//
// ZIPA writes one symbol per token, with no word boundaries, so a diphthong
// comes out as two symbols and nothing says where a sound ends. That is why
// the comparison works on UNITS (single symbols) on both sides, and a Phone
// knows which units it is made of: a Spanish speaker saying `e` for `eɪ`, or
// `ʝ` for `dʒ`, is then seen as that sound said differently, not as a
// scatter of unrelated symbols.
library;

/// One expected sound of a word.
class Phone {
  const Phone({
    required this.ipa,
    required this.stressed,
    required this.isVowel,
  });

  final String ipa;

  /// Primary or secondary stress. Unstressed vowels reduce freely in natural
  /// speech, so the comparison forgives them more.
  final bool stressed;

  final bool isVowel;

  /// The single symbols the phone model writes for this sound.
  List<String> get units => ipa.split('');
}

const Map<String, String> _vowels = {
  'AA': 'ɑ', 'AE': 'æ', 'AO': 'ɔ', 'AW': 'aʊ', 'AY': 'aɪ', 'EH': 'ɛ',
  'ER': 'ə˞', 'EY': 'eɪ', 'IH': 'ɪ', 'IY': 'i', 'OW': 'oʊ', 'OY': 'ɔɪ',
  'UH': 'ʊ', 'UW': 'u',
  // AH is split by stress below: schwa when unstressed, ʌ when stressed.
};

const Map<String, String> _consonants = {
  'B': 'b', 'CH': 'tʃ', 'D': 'd', 'DH': 'ð', 'F': 'f', 'G': 'g', 'HH': 'h',
  'JH': 'dʒ', 'K': 'k', 'L': 'l', 'M': 'm', 'N': 'n', 'NG': 'ŋ', 'P': 'p',
  'R': 'ɹ', 'S': 's', 'SH': 'ʃ', 'T': 't', 'TH': 'θ', 'V': 'v', 'W': 'w',
  'Y': 'j', 'Z': 'z', 'ZH': 'ʒ',
};

/// Converts one CMUdict pronunciation ("SH IH1 P") into phones.
List<Phone> arpabetToPhones(String arpabet) => [
      for (final symbol in arpabet.trim().split(RegExp(r'\s+')))
        _phone(symbol),
    ];

Phone _phone(String symbol) {
  final match = RegExp(r'^([A-Z]+)([012])?$').firstMatch(symbol);
  if (match == null) throw FormatException('Not ARPAbet: $symbol');
  final base = match.group(1)!;
  final stress = match.group(2);
  final consonant = _consonants[base];
  if (consonant != null && stress == null) {
    return Phone(ipa: consonant, stressed: false, isVowel: false);
  }
  if (stress == null) throw FormatException('Vowel without stress: $symbol');
  final ipa = base == 'AH' ? (stress == '0' ? 'ə' : 'ʌ') : _vowels[base];
  if (ipa == null) throw FormatException('Unknown ARPAbet symbol: $symbol');
  return Phone(ipa: ipa, stressed: stress != '0', isVowel: true);
}

/// Marks that change how a sound is said but not which sound it is, as far
/// as a learner's feedback goes: length, aspiration, nasalisation, release,
/// voicing and place diacritics, syllabicity, velarisation.
final RegExp _dropped = RegExp('[ːʰʲʷˠˤʼ\u0303\u031A\u0325\u0329\u032A\u0334\u033A]');

/// The phone model's output as single symbols, normalised to the inventory
/// the expected side uses.
List<String> heardUnits(String ipa) => [
      for (final unit in ipa.replaceAll(_dropped, '').split(''))
        if (unit.trim().isNotEmpty && unit != '▁') unit == 'ɜ' ? 'ə' : unit,
    ];

/// CMUdict trimmed to words a learner may meet, in the asset's line format:
/// `word ARPA ARPA|ARPA ARPA` (variants separated by `|`).
class PronLexicon {
  PronLexicon._(this._entries);

  factory PronLexicon.parse(String text) {
    final entries = <String, List<String>>{};
    for (final line in text.split('\n')) {
      final space = line.indexOf(' ');
      if (space <= 0) continue;
      entries[line.substring(0, space)] = line.substring(space + 1).split('|');
    }
    return PronLexicon._(entries);
  }

  final Map<String, List<String>> _entries;

  /// Every known pronunciation of [word]; empty when the word is not known.
  List<List<Phone>> lookup(String word) {
    final key = word.toLowerCase().replaceAll('’', "'");
    return [for (final v in _entries[key] ?? const <String>[]) arpabetToPhones(v)];
  }
}
