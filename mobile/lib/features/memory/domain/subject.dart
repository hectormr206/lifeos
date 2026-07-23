/// Family-subject marker detection (roadmap SLICE A3).
///
/// Ported 1:1 from `lifeos/src/lifeos/_common/subject.py`. Convention
/// (user-defined): the person an entry belongs to is stated at the START or
/// END of the message; unmarked text is the user themself.
///
///   "Mi esposa tuvo 121, 79, 61 pulsos"  -> subject "esposa", remainder parses
///   "108, 72, 66 pulsos de mi esposa"    -> subject "esposa"
///   "My wife slept 7 hours"              -> subject "esposa"
///
/// The subject is the canonical Spanish relation word so ES/EN and synonyms
/// ("mujer"/"wife") collapse into one label the graph layer can resolve against
/// the hub's typed relation edges.
///
/// Proper-name markers ("Ana tuvo ...") are deliberately NOT supported: without
/// a roster of known names the pattern `<Word> tuvo` is far too
/// false-positive-prone. Precision-first — a misdetect must never write a fact
/// against the wrong person.
///
/// Dart port note: Dart's `\b` is ASCII-only, and accented relation words
/// ("mamá", "tío") would break word boundaries. We therefore accent-FOLD the
/// text with a length-preserving 1:1 map ([foldAccents]) before matching, run
/// ASCII-only regexes, and slice the ORIGINAL text at the (index-stable) match
/// offsets to recover the remainder.
library;

/// Canonical ES relation label per accepted marker word. Keys are the
/// accent-FOLDED, lowercased forms (matching runs on folded text); values are
/// the canonical (accented) ES label emitted downstream.
const Map<String, String> _relationCanon = <String, String>{
  // ES
  'esposa': 'esposa', 'mujer': 'esposa',
  'esposo': 'esposo', 'marido': 'esposo',
  'mama': 'mamá', 'madre': 'mamá',
  'papa': 'papá', 'padre': 'papá',
  'hijo': 'hijo', 'hija': 'hija',
  'hermano': 'hermano', 'hermana': 'hermana',
  'abuelo': 'abuelo', 'abuela': 'abuela',
  'suegro': 'suegro', 'suegra': 'suegra',
  'tio': 'tío', 'tia': 'tía',
  'primo': 'primo', 'prima': 'prima',
  'novio': 'novio', 'novia': 'novia',
  // EN -> canonical ES label (single vocabulary downstream)
  'wife': 'esposa', 'husband': 'esposo',
  'mom': 'mamá', 'mother': 'mamá',
  'dad': 'papá', 'father': 'papá',
  'son': 'hijo', 'daughter': 'hija',
  'brother': 'hermano', 'sister': 'hermana',
};

/// Canonical ES relation label -> English relation word, for confirmation copy
/// in English installs ("your wife").
const Map<String, String> _enRelation = <String, String>{
  'esposa': 'wife', 'esposo': 'husband',
  'mamá': 'mom', 'papá': 'dad',
  'hijo': 'son', 'hija': 'daughter',
  'hermano': 'brother', 'hermana': 'sister',
  'abuelo': 'grandpa', 'abuela': 'grandma',
  'suegro': 'father-in-law', 'suegra': 'mother-in-law',
  'tío': 'uncle', 'tía': 'aunt',
  'primo': 'cousin', 'prima': 'cousin',
  'novio': 'boyfriend', 'novia': 'girlfriend',
};

/// Length-preserving accent fold: each accented Latin char -> its ASCII base,
/// 1:1, so match offsets stay valid against the original string.
String foldAccents(String input) {
  const map = <String, String>{
    'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a',
    'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
    'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
    'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o',
    'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
    'ñ': 'n',
    'Á': 'A', 'À': 'A', 'Ä': 'A', 'Â': 'A',
    'É': 'E', 'È': 'E', 'Ë': 'E', 'Ê': 'E',
    'Í': 'I', 'Ì': 'I', 'Ï': 'I', 'Î': 'I',
    'Ó': 'O', 'Ò': 'O', 'Ö': 'O', 'Ô': 'O',
    'Ú': 'U', 'Ù': 'U', 'Ü': 'U', 'Û': 'U',
    'Ñ': 'N',
  };
  final buffer = StringBuffer();
  for (final ch in input.split('')) {
    buffer.write(map[ch] ?? ch);
  }
  return buffer.toString();
}

/// Accent-folded + lowercased form, for case/accent-insensitive comparison.
String normalizeSubject(String s) => foldAccents(s.trim().toLowerCase());

// Relation alternation, folded keys sorted longest-first so "esposa" wins over
// a hypothetical shorter prefix.
final String _relationAlt = (_relationCanon.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length)))
    .map(RegExp.escape)
    .join('|');

// Third-person ES + simple-past EN verbs that may follow a LEADING marker,
// captured so callers can retry parsing without the verb. Accent-folded forms.
const String _verbAlt = r'tuvo|tiene|tenia|trae|anda\s+con|midio|se\s+midio|marco'
    r'|registro|peso|se\s+peso|dijo|durmio|hizo|se\s+tomo|tomo'
    r'|had|has|got|did|took|measured|weighed|slept|said|is|was';

// Leading: "mi esposa [tuvo] ..." / "my wife [had] ..." — anchored at the start.
final RegExp _leadingRe = RegExp(
  r'^\s*(?:mi|my)\s+(?<rel>' +
      _relationAlt +
      r')\b(?:\s+(?<verb>' +
      _verbAlt +
      r')\b)?[\s:,]*',
  caseSensitive: false,
);

// Trailing: "... de mi esposa" / "... of my wife" — anchored at the end.
final RegExp _trailingRe = RegExp(
  r'[\s,;]*\b(?:de|of)\s+(?:mi|my)\s+(?<rel>' +
      _relationAlt +
      r')\s*[.!?]?\s*$',
  caseSensitive: false,
);

// Query-oriented: a possessive family marker ANYWHERE in a free-form question.
// The required "mi|my" possessive is the false-positive guard.
final RegExp _queryRe = RegExp(
  r'\b(?:mi|my)\s+(?<rel>' + _relationAlt + r')\b',
  caseSensitive: false,
);

// Loose/ingestion-oriented: a possessive family marker ANYWHERE, optionally led
// by a preposition ("de/a/con/para/of/for/to/with mi <rel>"). Used by the
// structured-capture path so a marker that sits neither at the exact start
// ("de mi esposa son 120, 60, 49 pulsos") nor at the exact end ("esto le salió a
// mi papá 135, 89, 95 pulsos") is still attributed. The "mi|my" possessive is
// the false-positive guard — a self reading ("mi presión 120/80") has no
// relation word and never matches.
final RegExp _looseRe = RegExp(
  <String>[
    r'(?:\b(?:de|a|con|para|of|for|to|with)\s+)?\b(?:mi|my)\s+(?<rel>',
    _relationAlt,
    r')\b',
  ].join(),
  caseSensitive: false,
);

/// A detected family-subject marker plus the marker-stripped remainder(s).
class SubjectMatch {
  const SubjectMatch({
    required this.subject,
    required this.remainder,
    this.remainderNoVerb,
  });

  /// Canonical ES relation label ("esposa").
  final String subject;

  /// Original text with the marker stripped.
  final String remainder;

  /// Leading form with the verb ALSO stripped (null when no verb / trailing).
  final String? remainderNoVerb;
}

String _canon(String rel) => _relationCanon[foldAccents(rel.toLowerCase())]!;

/// The folded relation-word alternation (longest-first), shared with adjacent
/// ingestion parsers (e.g. person naming) so there is ONE relation vocabulary.
String get relationAlternation => _relationAlt;

/// Canonical ES relation label for an already accent-folded, lowercased
/// relation word ("papa" → "papá"), or null when it is not a known relation.
String? canonRelation(String foldedRel) => _relationCanon[foldedRel];

/// Detect a family-subject marker at the start or end of [text].
///
/// Returns the canonical subject plus the marker-stripped remainder(s), or
/// null when the text is unmarked (-> the entry belongs to the user).
SubjectMatch? detectSubject(String? text) {
  if (text == null || text.isEmpty) return null;
  final folded = foldAccents(text);

  final lead = _leadingRe.firstMatch(folded);
  if (lead != null) {
    String? remainderNoVerb;
    String remainder;
    final verb = lead.namedGroup('verb');
    if (verb != null && verb.isNotEmpty) {
      // remainder keeps the verb (some grammars key off "slept 7 hours");
      // remainderNoVerb drops it for start-anchored grammars.
      final verbStart = folded.indexOf(verb, lead.start);
      remainder = text.substring(verbStart >= 0 ? verbStart : lead.end).trim();
      remainderNoVerb = text.substring(lead.end).trim();
    } else {
      remainder = text.substring(lead.end).trim();
    }
    if (remainder.isNotEmpty ||
        (remainderNoVerb != null && remainderNoVerb.isNotEmpty)) {
      return SubjectMatch(
        subject: _canon(lead.namedGroup('rel')!),
        remainder: remainder,
        remainderNoVerb:
            (remainderNoVerb != null && remainderNoVerb.isNotEmpty)
                ? remainderNoVerb
                : null,
      );
    }
  }

  final trail = _trailingRe.firstMatch(folded);
  if (trail != null) {
    final remainder = text.substring(0, trail.start).trim();
    if (remainder.isNotEmpty) {
      return SubjectMatch(
        subject: _canon(trail.namedGroup('rel')!),
        remainder: remainder,
      );
    }
  }
  return null;
}

/// Detect the family subject a free-form [query] is about.
///
/// Scans the whole query for a possessive family marker ("mi esposa",
/// "my wife") in any position and returns the canonical relation label, or
/// null when the query is about the user themself (-> self).
String? detectQuerySubject(String? query) {
  if (query == null || query.isEmpty) return null;
  final m = _queryRe.firstMatch(foldAccents(query));
  return m == null ? null : _canon(m.namedGroup('rel')!);
}

/// Loose family-subject detection for the STRUCTURED-CAPTURE ingestion path.
///
/// Unlike [detectSubject] (start/end-anchored, clean marker strip), this catches
/// a possessive family marker ANYWHERE — including a leading `de mi <rel>` or a
/// mid-sentence `a mi <rel>` — and returns the canonical relation label plus the
/// text with just the marker phrase blanked out. The remainder still contains
/// the reading's numbers (the metric parser is un-anchored), so it parses even
/// with leftover filler. Returns null when no possessive family marker is
/// present (→ the entry is the user's own). Precision guard: the "mi|my"
/// possessive is required, so a self reading never matches.
SubjectMatch? detectSubjectLoose(String? text) {
  if (text == null || text.isEmpty) return null;
  final m = _looseRe.firstMatch(foldAccents(text));
  if (m == null) return null;
  final remainder =
      '${text.substring(0, m.start)} ${text.substring(m.end)}'.trim();
  return SubjectMatch(
    subject: _canon(m.namedGroup('rel')!),
    remainder: remainder,
  );
}

/// Possessive phrasing for a family subject, for chat confirmations.
/// `subjectPossessive("esposa")` -> "tu esposa"; with [en] -> "your wife".
String subjectPossessive(String subject, {bool en = false}) {
  final rel = subject.trim();
  if (en) return 'your ${_enRelation[rel.toLowerCase()] ?? rel}';
  return 'tu $rel';
}
