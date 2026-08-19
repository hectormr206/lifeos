// What someone just told us about a person.
//
// The point of this feature is a dinner two months from now: knowing that
// Juan's son Mateo is 8 and plays football is what makes a person feel
// remembered. "Juan tiene dos hijos" is worth nothing at that dinner, so the
// DETAIL is the whole product — names and ages, not counts.
//
// Read in Dart rather than by asking a ~2B model for clean JSON. The model
// would return something plausible every time, including when the sentence
// said no such thing, and an invented detail about someone's family is worse
// than no detail: it gets repeated to their face.
//
// Extracts only what was SAID. No inferred ages, no guessed relationships,
// nothing when it cannot parse — the ordinary capture path still runs.
library;

/// One thing known about a person.
class PersonFact {
  const PersonFact({
    required this.subject,
    required this.kind,
    required this.value,
    this.detail,
  });

  /// Who it is about. Never empty: a fact with no owner is the bug this whole
  /// area exists to prevent.
  final String subject;

  /// 'hijos', 'hijo', 'esposa', 'papá', 'trabajo', 'gusto', 'vive en'…
  final String kind;
  final String value;

  /// The age, when one was given. Null means nobody said — never a guess.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is PersonFact &&
      other.subject == subject &&
      other.kind == kind &&
      other.value == value &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(subject, kind, value, detail);

  @override
  String toString() => 'PersonFact($subject, $kind=$value, detail=$detail)';
}

const Map<String, int> _spelledNumbers = {
  'un': 1, 'una': 1, 'uno': 1, 'dos': 2, 'tres': 3, 'cuatro': 4, 'cinco': 5,
  'seis': 6, 'siete': 7, 'ocho': 8, 'nueve': 9, 'diez': 10,
};

String? _number(String word) {
  final digits = int.tryParse(word);
  if (digits != null) return '$digits';
  final spelled = _spelledNumbers[word.toLowerCase()];
  return spelled?.toString();
}

/// Everything the sentence says about [subject].
///
/// Returns empty when there is no subject: no owner, no fact. That single rule
/// is what keeps one person's life from being filed under another's.
List<PersonFact> personFactsIn(String message, {required String? subject}) {
  if (subject == null || subject.trim().isEmpty) return const [];
  // A question asks about a person; it states nothing about them.
  if (RegExp(r'[?¿]').hasMatch(message)) return const [];

  final text = message.trim();
  final facts = <PersonFact>[];
  void add(String kind, String value, {String? detail}) {
    final clean = value.trim();
    if (clean.isEmpty) return;
    facts.add(PersonFact(
        subject: subject, kind: kind, value: clean, detail: detail));
  }

  // A named child, with an age when one was given: the detail that makes this
  // worth storing at all.
  final namedChild = RegExp(
      r'\b(?:su|el|la)?\s*(hijo|hija)\s+([\p{Lu}][\p{L}]+)'
      r'(?:\s+(?:tiene|de)\s+(\d{1,2}|\p{L}+)\s*(?:años?)?)?',
      unicode: true);
  for (final m in namedChild.allMatches(text)) {
    add(m.group(1)!, m.group(2)!,
        detail: m.group(3) == null ? null : _number(m.group(3)!));
  }

  // "su hijo se llama Mateo"
  final childNamed = RegExp(
      r'\b(?:su|el|la)?\s*(hijo|hija)\s+se\s+llama\s+([\p{Lu}][\p{L}]+)',
      unicode: true);
  for (final m in childNamed.allMatches(text)) {
    add(m.group(1)!, m.group(2)!);
  }

  // A COUNT of children, only when no name was given — "tiene dos hijos".
  if (!facts.any((f) => f.kind == 'hijo' || f.kind == 'hija')) {
    final count = RegExp(r'\btiene\s+(\d{1,2}|\p{L}+)\s+hijos?\b', unicode: true)
        .firstMatch(text);
    final n = count == null ? null : _number(count.group(1)!);
    if (n != null) add('hijos', n);
  }

  // Spouse and parents by name.
  final bonds = RegExp(
      r'\b(?:su\s+)?(esposa|esposo|mujer|marido|pareja|mamá|mama|papá|papa|'
      r'madre|padre|hermano|hermana)\s+(?:se\s+llama\s+|es\s+)([\p{Lu}][\p{L}]+)',
      unicode: true, caseSensitive: false);
  for (final m in bonds.allMatches(text)) {
    add(m.group(1)!.toLowerCase(), m.group(2)!);
  }

  // Where they work. Stops at a comma or a clause break so "trabaja en Bimbo y
  // le gusta el futbol" does not store the whole tail as an employer.
  final work = RegExp(r'\btrabaja\s+en\s+([^,.;]+?)(?:\s+y\s|[,.;]|$)',
      unicode: true);
  final workMatch = work.firstMatch(text);
  if (workMatch != null) add('trabajo', workMatch.group(1)!);

  // Where they live.
  final lives = RegExp(r'\bvive\s+en\s+([^,.;]+?)(?:\s+y\s|[,.;]|$)',
      unicode: true);
  final livesMatch = lives.firstMatch(text);
  if (livesMatch != null) add('vive en', livesMatch.group(1)!);

  // What they like — the conversational gold.
  final likes = RegExp(r'\ble\s+(?:gusta|gustan|encanta|encantan)\s+'
      r'([^,.;]+?)(?:\s+y\s|[,.;]|$)', unicode: true);
  final likesMatch = likes.firstMatch(text);
  if (likesMatch != null) add('gusto', likesMatch.group(1)!);

  return facts;
}

/// The facts as sentences, for the memory block a conversation reads from.
List<String> describePersonFacts(List<PersonFact> facts) => [
      for (final fact in facts)
        switch (fact.kind) {
          'hijos' => '${fact.subject} tiene ${fact.value} hijos.',
          'hijo' || 'hija' => fact.detail == null
              ? '${fact.kind == 'hijo' ? 'El hijo' : 'La hija'} de '
                  '${fact.subject} se llama ${fact.value}.'
              : '${fact.kind == 'hijo' ? 'El hijo' : 'La hija'} de '
                  '${fact.subject}, ${fact.value}, tiene ${fact.detail} años.',
          'trabajo' => '${fact.subject} trabaja en ${fact.value}.',
          'vive en' => '${fact.subject} vive en ${fact.value}.',
          'gusto' => 'A ${fact.subject} le gusta ${fact.value}.',
          _ => 'La ${fact.kind} de ${fact.subject} es ${fact.value}.',
        },
    ];
