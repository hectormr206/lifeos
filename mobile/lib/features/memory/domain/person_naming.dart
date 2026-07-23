/// DETERMINISTIC explicit name/nickname learning for family-relation people.
///
/// Ports the *deterministic* half of the laptop identity name-learning: when the
/// user explicitly states the NAME or the NICKNAME of a known relation, we set it
/// on that relation's person node instead of leaving it labelled by the bare
/// relation word ("esposa" → "Celia", alias "Cely"). Precision-first: the
/// relation word anchors WHICH person the name is for, so an ungrounded
/// "le digo Cely" (no relation) is deliberately NOT matched.
///
/// Recognised (ES):
///   * "mi esposa se llama Celia"        → name  = Celia   (relation esposa)
///   * "a mi papá le digo/decimos Beto"  → alias = Beto    (relation papá)
///   * "a mi esposa le decimos Cely"     → alias = Cely
///
/// Matching runs on [foldAccents]-ed, lowercased text (Dart `\b`/relation
/// vocabulary are ASCII); the NAME/ALIAS itself is recovered from the ORIGINAL
/// text (offset-stable, since folding is length-preserving 1:1) so its
/// capitalization and accents survive.
library;

import 'subject.dart';

/// A parsed explicit naming statement for a relation's person node.
class PersonNaming {
  const PersonNaming({required this.relation, this.name, this.alias});

  /// Canonical ES relation label the name/alias belongs to ("esposa").
  final String relation;

  /// The stated formal name ("Celia"), or null when only a nickname was given.
  final String? name;

  /// The stated nickname/alias ("Cely"), or null when only a name was given.
  final String? alias;
}

final RegExp _nameRe = RegExp(
  <String>[
    r'\b(?:a\s+)?mi\s+(?<rel>',
    relationAlternation,
    r')\s+se\s+llama\s+(?<name>[a-z]+)',
  ].join(),
  caseSensitive: false,
);

final RegExp _aliasRe = RegExp(
  <String>[
    r'\b(?:a\s+)?mi\s+(?<rel>',
    relationAlternation,
    r')\s+(?:le\s+)?(?:digo|decimos|dicen|llamo|llamamos)\s+(?<nick>[a-z]+)',
  ].join(),
  caseSensitive: false,
);

/// Detect an explicit name/nickname statement for a relation, or null.
PersonNaming? detectPersonNaming(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  final folded = foldAccents(text);

  final n = _nameRe.firstMatch(folded);
  if (n != null) {
    final rel = canonRelation(n.namedGroup('rel')!);
    final name = _sliceTail(text, n, n.namedGroup('name')!);
    if (rel != null && name.isNotEmpty) {
      return PersonNaming(relation: rel, name: name);
    }
  }

  final a = _aliasRe.firstMatch(folded);
  if (a != null) {
    final rel = canonRelation(a.namedGroup('rel')!);
    final nick = _sliceTail(text, a, a.namedGroup('nick')!);
    if (rel != null && nick.isNotEmpty) {
      return PersonNaming(relation: rel, alias: nick);
    }
  }
  return null;
}

/// Recover the ORIGINAL-case tail (the name/alias) that sits at the very end of
/// the match, using the folded group's length (offsets align because folding is
/// 1:1). Both naming regexes end exactly on the name/alias group.
String _sliceTail(String original, RegExpMatch m, String foldedTail) {
  final end = m.end;
  final start = end - foldedTail.length;
  if (start < 0 || start > original.length || end > original.length) {
    return foldedTail; // defensive: fall back to the folded form
  }
  return original.substring(start, end).trim();
}
