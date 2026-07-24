/// DETERMINISTIC capture of the USER's OWN name from a chat message (first-run
/// onboarding, roadmap SLICE C1 follow-up).
///
/// Sibling of [detectPersonNaming] (which learns a FAMILY relation's name); this
/// one learns how the USER themself wants to be called, so Axi can address them
/// by name and "yo/mi" anchors to the user hub.
///
/// Two modes:
///   * EXPLICIT forms, accepted anytime the name is still unknown:
///       "me llamo Héctor" · "soy Héctor" · "llámame Héctor" ·
///       "me puedes decir Héctor" · "me dicen/llaman Héctor" ·
///       "mi nombre es Héctor" · "dime Héctor" · "puedes llamarme Héctor".
///   * BARE answer ([bareAllowed]) — the WHOLE message is treated as the name
///     (a reply of just "Héctor" to Axi's onboarding question). Guarded so a
///     deflection ("cuéntame un chiste") or a health log ("122 80 pulsos") is
///     never mistaken for a name.
///
/// Precision-first: matching runs on [foldAccents]-ed, lowercased text (folding
/// is length-preserving 1:1) so the name is sliced back from the ORIGINAL text
/// with its accents/casing intact. Returns the cleaned display name, or null.
library;

import 'subject.dart';

/// Leading phrases that explicitly introduce the user's own name, folded +
/// lowercased (matching runs on folded text). Longest-first so "me puedes decir"
/// wins over "me".
const List<String> _namePrefixes = <String>[
  'me puedes decir',
  'puedes llamarme',
  'puedes decirme',
  'mi nombre es',
  'me llamo',
  'me dicen',
  'me llaman',
  'llamame',
  'dime',
  'soy',
];

final RegExp _prefixRe = RegExp(
  '^\\s*(?:${_namePrefixes.map(RegExp.escape).join('|')})\\s+(.+)\$',
  caseSensitive: false,
);

/// Common non-name words a BARE (or "soy …") reply might carry — a deflection,
/// greeting, or short command — that must NOT be stored as the user's name.
/// Folded + lowercased. Precision guard for the onboarding bare-answer path.
const Set<String> _notNameWords = <String>{
  // ES
  'no', 'si', 'hola', 'que', 'como', 'cuando', 'donde', 'quien', 'cual',
  'cuanto', 'gracias', 'adios', 'bien', 'mal', 'nada', 'nadie', 'algo',
  'ayuda', 'ayudame', 'quiero', 'necesito', 'cuenta', 'cuentame', 'chiste',
  'broma', 'recuerda', 'recuerdame', 'comprar', 'llamar', 'tomar', 'presion',
  'pulso', 'pulsos', 'peso', 'hoy', 'ayer', 'manana', 'ok', 'vale', 'claro',
  'feliz', 'cansado', 'triste', 'enojado', 'ingeniero', 'programador',
  'medico', 'doctor', 'gato', 'perro', 'usted', 'ella',
  // EN
  'yes', 'hi', 'hello', 'what', 'how', 'when', 'where', 'who', 'thanks',
  'nothing', 'help', 'tell', 'joke', 'buy', 'call', 'remind', 'blood',
  'pulse', 'weight', 'today', 'sure', 'you', 'name', 'happy', 'tired',
  'engineer', 'programmer',
};

/// A single name token: a letter (incl. accented) followed by letters, an
/// internal hyphen or apostrophe. 2–20 chars.
final RegExp _nameTokenRe = RegExp(
  r"^[a-zà-öø-ÿ][a-zà-öø-ÿ'’-]{1,19}$",
  caseSensitive: false,
);

/// Parse the user's own name from [text], or null when nothing name-like.
///
/// [bareAllowed] enables the onboarding bare-answer path (the whole message may
/// be the name). When false, only the explicit `me llamo …` / `soy …` forms are
/// accepted — so a normal message is never mistaken for a name.
String? parseUserName(String? text, {required bool bareAllowed}) {
  if (text == null) return null;
  final original = text.trim();
  if (original.isEmpty) return null;
  final folded = foldAccents(original);

  final m = _prefixRe.firstMatch(folded);
  if (m != null) {
    // The captured group runs to end-of-string, so its start offset in the
    // (length-preserving) folded text maps 1:1 onto the original.
    final tailStart = m.end - m.group(1)!.length;
    final candidate = _clean(original.substring(tailStart));
    if (_looksLikeName(candidate)) return _titleCase(candidate);
    return null;
  }

  if (!bareAllowed) return null;
  final candidate = _clean(original);
  if (_looksLikeName(candidate)) return _titleCase(candidate);
  return null;
}

/// Trim surrounding punctuation/space, collapse inner whitespace, and cap to the
/// first 3 tokens / 40 chars so a trailing clause can't bloat the stored name.
String _clean(String raw) {
  var s = raw.trim();
  // Strip leading/trailing punctuation (keep inner hyphens/apostrophes).
  s = s.replaceAll(RegExp(r'''^[\s.,;:!?¿¡"'`()\[\]{}]+'''), '');
  s = s.replaceAll(RegExp(r'''[\s.,;:!?¿¡"'`()\[\]{}]+$'''), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  final tokens = s.split(' ').where((t) => t.isNotEmpty).take(3).toList();
  s = tokens.join(' ');
  return s.length <= 40 ? s : s.substring(0, 40).trim();
}

/// True when [candidate] is 1–3 clean, letter-only name tokens and none is an
/// obvious non-name word — the precision guard for the bare-answer path.
bool _looksLikeName(String candidate) {
  if (candidate.isEmpty) return false;
  if (candidate.contains(RegExp(r'[0-9]'))) return false;
  final tokens = candidate.split(' ').where((t) => t.isNotEmpty).toList();
  if (tokens.isEmpty || tokens.length > 3) return false;
  for (final tok in tokens) {
    if (!_nameTokenRe.hasMatch(tok)) return false;
    if (_notNameWords.contains(foldAccents(tok.toLowerCase()))) return false;
  }
  return true;
}

/// Capitalize the first letter of each token (leaving the rest as typed) so a
/// lowercase "héctor" is stored as "Héctor" for the confirmation copy.
String _titleCase(String s) => s
    .split(' ')
    .where((t) => t.isNotEmpty)
    .map((t) => t.length == 1
        ? t.toUpperCase()
        : '${t.substring(0, 1).toUpperCase()}${t.substring(1)}')
    .join(' ');
