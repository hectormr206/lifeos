// "No, Mateo tiene 9" — correcting Axi by talking to it.
//
// Data goes IN by talking, and until now the only way to fix it was to find
// the row and edit it by hand. Almost nobody does that, so the errors stay.
//
// And a wrong fact is not inert: it gets repeated. The day Axi tells someone
// their friend's son is a year younger, in front of the friend, the trust in
// the whole memory is gone — and you only get to break that once.
//
// Recognised in Dart, BEFORE anything tries to store the sentence: left to the
// ordinary capture path, "no, Mateo tiene 9" became a second, contradictory
// entry, and recall could then return either one.
library;

import '../../memory/domain/subject.dart' show foldAccents;

/// Openers that mark the turn as fixing something already said.
///
/// Deliberately narrow, and anchored at the START. "No me acuerdo" and "no sé
/// qué hacer" also begin with "no" and correct nothing; treating them as
/// corrections would delete a real fact on the strength of a filler word.
final List<RegExp> _openers = [
  RegExp(r'^\s*no,\s+'),
  RegExp(r'^\s*no\s+es\s+\S+,\s+'),
  RegExp(r'^\s*me\s+equivoque[,:]?\s*'),
  RegExp(r'^\s*corrige[,:]?\s*'),
  RegExp(r'^\s*correccion[,:]?\s*'),
  RegExp(r'^\s*perdon,?\s+quise\s+decir\s+'),
  RegExp(r'^\s*quise\s+decir\s+'),
];

/// True when the turn is fixing something, not stating something new.
bool looksLikeCorrection(String message) {
  // A question never corrects: "¿no era 9?" is asking, not telling.
  if (RegExp(r'[?¿]').hasMatch(message)) return false;
  final folded = foldAccents(message.toLowerCase());
  return _openers.any((r) => r.hasMatch(folded));
}

/// What the correction SAYS, with the opener removed — or null when it says
/// only that something is wrong.
///
/// "Me equivoqué" alone marks an error without naming the fix; storing a blank
/// would erase the original and put nothing in its place.
String? correctionPayload(String message) {
  if (!looksLikeCorrection(message)) return null;

  final folded = foldAccents(message.toLowerCase());
  for (final opener in _openers) {
    final match = opener.firstMatch(folded);
    if (match == null) continue;
    // Cut the ORIGINAL string at the same offset, so accents and capitals
    // survive: the stored fact is read back to the user, and "mateo" instead
    // of "Mateo" is a person's name spelled wrong.
    final rest = message.substring(match.end).trim();
    return rest.isEmpty ? null : rest;
  }
  return null;
}
