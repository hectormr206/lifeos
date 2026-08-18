// Answering "¿quién es X?" from the graph, without asking the model.
//
// Measured on the test Pixel: with "mi hermana se llama Laura" stored and the
// recall provably correct — the diagnostic showed two facts, both about Laura —
// the ~2B model still answered "Laura es tu esposa". The context was right and
// the GENERATION was wrong, and four rounds of prompt rules only moved the
// error around.
//
// Kinship is the one thing a person will never forgive being told wrongly, and
// it is also the easiest to read straight out of the stored sentence. So this
// answers it directly, the same way the capture layer already short-circuits a
// health value.
//
// IT ANSWERS ONLY WHEN CERTAIN. One readable bond, or nothing stored at all.
// Anything ambiguous — no bond word, or two different ones — falls through to
// the model, because a deterministic wrong answer is worse than a hedge.
library;

/// Kinship words this can read, and the word it answers with.
///
/// Spanish and English together: the install language decides the phrasing, not
/// which words are understood — a bilingual user writes "my wife" on Monday and
/// "mi esposa" on Tuesday about the same person.
const Map<String, String> _bondsEs = {
  'esposa': 'esposa', 'esposo': 'esposo', 'marido': 'marido',
  'hija': 'hija', 'hijo': 'hijo', 'madre': 'madre', 'padre': 'padre',
  'mamá': 'mamá', 'papá': 'papá', 'hermana': 'hermana', 'hermano': 'hermano',
  'novia': 'novia', 'novio': 'novio', 'jefa': 'jefa', 'jefe': 'jefe',
  'colega': 'colega', 'amiga': 'amiga', 'amigo': 'amigo',
  'suegra': 'suegra', 'suegro': 'suegro', 'tía': 'tía', 'tío': 'tío',
  'prima': 'prima', 'primo': 'primo', 'abuela': 'abuela', 'abuelo': 'abuelo',
  'nieta': 'nieta', 'nieto': 'nieto', 'cuñada': 'cuñada', 'cuñado': 'cuñado',
  'wife': 'esposa', 'husband': 'esposo', 'daughter': 'hija', 'son': 'hijo',
  'mother': 'madre', 'father': 'padre', 'sister': 'hermana',
  'brother': 'hermano', 'boss': 'jefe', 'colleague': 'colega',
  'friend': 'amigo', 'girlfriend': 'novia', 'boyfriend': 'novio',
};

const Map<String, String> _bondsEn = {
  'wife': 'wife', 'husband': 'husband', 'daughter': 'daughter', 'son': 'son',
  'mother': 'mother', 'father': 'father', 'sister': 'sister',
  'brother': 'brother', 'boss': 'boss', 'colleague': 'colleague',
  'friend': 'friend', 'girlfriend': 'girlfriend', 'boyfriend': 'boyfriend',
  'esposa': 'wife', 'esposo': 'husband', 'marido': 'husband',
  'hija': 'daughter', 'hijo': 'son', 'madre': 'mother', 'padre': 'father',
  'hermana': 'sister', 'hermano': 'brother', 'jefa': 'boss', 'jefe': 'boss',
  'colega': 'colleague', 'amiga': 'friend', 'amigo': 'friend',
};

/// The person a message is ASKING about, or null when it is not that question.
///
/// Deliberately narrow. It must never swallow a statement ("Laura es mi
/// hermana") — that belongs to the capture layer — nor a question about
/// anything else.
String? personAskedAbout(String message) {
  final patterns = <RegExp>[
    RegExp(r'qui[eé]n\s+es\s+([\p{Lu}][\p{L}]+)', unicode: true,
        caseSensitive: false),
    RegExp(r'qu[eé]\s+relaci[oó]n\s+tengo\s+con\s+([\p{Lu}][\p{L}]+)',
        unicode: true, caseSensitive: false),
    RegExp(r'who\s+is\s+([\p{Lu}][\p{L}]+)', unicode: true,
        caseSensitive: false),
    RegExp(r'relationship\s+.*?\bwith\s+([\p{Lu}][\p{L}]+)', unicode: true,
        caseSensitive: false),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(message);
    if (match != null) return match.group(1);
  }
  return null;
}

/// The answer, or null to let the model handle it.
String? answerAboutPerson({
  required String name,
  required List<String> facts,
  required String languageCode,
}) {
  final en = languageCode == 'en';
  final vocabulary = en ? _bondsEn : _bondsEs;

  final about = [
    for (final f in facts)
      if (f.toLowerCase().contains(name.toLowerCase())) f.toLowerCase(),
  ];

  // Nothing at all about this person: say so. This is the case the model
  // answered with an invented bond ("Mariana es tu esposa").
  if (about.isEmpty) {
    return en ? 'I do not know who $name is.' : 'No sé quién es $name.';
  }

  final found = <String>{};
  for (final line in about) {
    vocabulary.forEach((word, canonical) {
      if (RegExp('(?<![\\p{L}])$word(?![\\p{L}])', unicode: true)
          .hasMatch(line)) {
        found.add(canonical);
      }
    });
  }

  // No bond word, or more than one: genuinely ambiguous. The model phrases
  // that better than a template, and guessing here would be the same mistake
  // in a different layer.
  if (found.length != 1) return null;

  final bond = found.first;
  return en ? '$name is your $bond.' : '$name es tu $bond.';
}

/// A kinship STATEMENT and what it says: ("hermana", "Laura").
///
/// "Mi hermana se llama Laura" reached the capture triage and produced no
/// entry, so nothing was stored — and the next turn Axi correctly said it did
/// not know her. Telling someone about your sister and having it forgotten is
/// the plainest possible failure of a memory.
///
/// Statements only. A question ("¿quién es Laura?") returns null: that belongs
/// to [personAskedAbout], and treating it as a statement would store the
/// question as if it were a fact.
({String bond, String name})? kinshipStatement(String message) {
  if (RegExp(r'[?¿]').hasMatch(message)) return null;

  final bonds = _bondsEs.keys.map(RegExp.escape).join('|');
  final patterns = <RegExp>[
    // "mi hermana se llama Laura" / "my sister is called Laura"
    RegExp('\\b(?:mi|my)\\s+($bonds)\\s+(?:se\\s+llama|is\\s+called|is)\\s+'
        r'([\p{Lu}][\p{L}]+)', unicode: true, caseSensitive: false),
    // "Laura es mi hermana" / "Laura is my sister"
    RegExp(r'([\p{Lu}][\p{L}]+)\s+(?:es|is)\s+(?:mi|my)\s+'
        '($bonds)', unicode: true, caseSensitive: false),
  ];

  for (var i = 0; i < patterns.length; i++) {
    final m = patterns[i].firstMatch(message);
    if (m == null) continue;
    final bond = (i == 0 ? m.group(1) : m.group(2))!.toLowerCase();
    final name = (i == 0 ? m.group(2) : m.group(1))!;
    // `caseSensitive: false` makes `\p{Lu}` match lowercase too, so the capital
    // is checked here instead: without it "mi hermana se llama como mi abuela"
    // stored a person called "como".
    if (name[0].toUpperCase() != name[0] ||
        name[0].toLowerCase() == name[0]) {
      continue;
    }
    return (bond: _bondsEs[bond] ?? bond, name: name);
  }
  return null;
}
