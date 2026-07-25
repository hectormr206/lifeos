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
/// STRONG prefixes semantically introduce a NAME and nothing else ("me llamo
/// diabético" is not Spanish), so a lowercase dictated name after them is
/// accepted. WEAK prefixes ("soy …", "dime …") also introduce predicates and
/// commands ("soy diabético", "dime la hora"), so their candidate must ALSO
/// look like a proper name (every token capitalized in the original text).
const List<String> _strongPrefixes = <String>[
  'me puedes decir',
  'puedes llamarme',
  'puedes decirme',
  'mi nombre es',
  'me llamo',
  'me dicen',
  'me llaman',
  'llamame',
];

const List<String> _weakPrefixes = <String>[
  'dime',
  'soy',
];

final RegExp _strongPrefixRe = RegExp(
  '^\\s*(?:${_strongPrefixes.map(RegExp.escape).join('|')})\\s+(.+)\$',
  caseSensitive: false,
);

final RegExp _weakPrefixRe = RegExp(
  '^\\s*(?:${_weakPrefixes.map(RegExp.escape).join('|')})\\s+(.+)\$',
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
  'feliz', 'cansado', 'cansada', 'triste', 'enojado', 'enojada',
  'ingeniero', 'ingeniera', 'programador', 'programadora',
  'medico', 'medica', 'doctor', 'doctora', 'gato', 'perro', 'usted', 'ella',
  // ES — conditions / states / professions / demonyms a "soy …" often carries
  // (they must NEVER be stored as the user's name).
  'diabetico', 'diabetica', 'hipertenso', 'hipertensa', 'enfermo', 'enferma',
  'alergico', 'alergica', 'asmatico', 'asmatica', 'soltero', 'soltera',
  'casado', 'casada', 'viudo', 'viuda', 'jubilado', 'jubilada',
  'maestro', 'maestra', 'abogado', 'abogada', 'enfermero', 'enfermera',
  'contador', 'contadora', 'arquitecto', 'arquitecta', 'estudiante',
  'mexicano', 'mexicana', 'nuevo', 'nueva',
  // ES — articles / pronouns / common command-object words so "dime la hora" /
  // "soy el que…" never parse as names.
  'el', 'la', 'los', 'las', 'un', 'una', 'de', 'del', 'yo', 'tu', 'mi',
  'hora', 'fecha', 'alarma', 'recordatorio', 'consejo', 'consejos',
  'puedes', 'quieres', 'dame', 'pon', 'hazme', 'hablemos', 'hablar',
  'espanol', 'ingles', 'favor', 'por', 'aqui', 'alla',
  // EN
  'yes', 'hi', 'hello', 'what', 'how', 'when', 'where', 'who', 'thanks',
  'nothing', 'help', 'tell', 'joke', 'buy', 'call', 'remind', 'blood',
  'pulse', 'weight', 'today', 'sure', 'you', 'name', 'happy', 'tired',
  'engineer', 'programmer', 'diabetic', 'sick', 'single', 'married',
  'nurse', 'teacher', 'lawyer', 'student', 'the', 'time',
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

  final strong = _strongPrefixRe.firstMatch(folded);
  if (strong != null) {
    // The captured group runs to end-of-string, so its start offset in the
    // (length-preserving) folded text maps 1:1 onto the original. Strong
    // prefixes only ever introduce a name, so a lowercase dictated "me llamo
    // hector" is still accepted (shape + stop-list guarded).
    final tailStart = strong.end - strong.group(1)!.length;
    final candidate = _clean(original.substring(tailStart));
    if (_looksLikeName(candidate)) return _titleCase(candidate);
    return null;
  }

  final weak = _weakPrefixRe.firstMatch(folded);
  if (weak != null) {
    // Weak prefixes ("soy …", "dime …") also introduce predicates and commands
    // ("soy diabético", "dime la hora"), so beyond the shape/stop-list guard
    // every token must be CAPITALIZED in the original text — "Soy Héctor" is a
    // name, "soy cansado" is not. This path never falls through to the bare
    // path: a prefixed sentence whose tail is not a name is simply no name.
    final tailStart = weak.end - weak.group(1)!.length;
    final candidate = _clean(original.substring(tailStart));
    if (_looksLikeName(candidate) && _allTokensCapitalized(candidate)) {
      return _titleCase(candidate);
    }
    return null;
  }

  if (!bareAllowed) return null;
  final candidate = _clean(original);
  if (_looksLikeName(candidate)) return _titleCase(candidate);
  return null;
}

/// Trim surrounding punctuation/space and collapse inner whitespace. The
/// candidate is deliberately NOT truncated here: the 1–3-token precision guard
/// in [_looksLikeName] must count the FULL reply, so a long sentence ("dame
/// consejos para dormir mejor") is rejected instead of silently shortened into
/// a fake 3-token "name".
String _clean(String raw) {
  var s = raw.trim();
  // Strip leading/trailing punctuation (keep inner hyphens/apostrophes).
  s = s.replaceAll(RegExp(r'''^[\s.,;:!?¿¡"'`()\[\]{}]+'''), '');
  s = s.replaceAll(RegExp(r'''[\s.,;:!?¿¡"'`()\[\]{}]+$'''), '');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Name particles ("María de Lourdes", "Juan de la Cruz") — allowed INSIDE a
/// multi-token name, but never as its first token ("de Monterrey" is a place,
/// "el que te dijo…" is a clause).
const Set<String> _nameParticles = <String>{'de', 'del', 'la', 'los', 'las'};

/// True when [candidate] is 1–3 clean, letter-only name tokens, at most
/// 40 chars, and none is an obvious non-name word — the precision guard shared
/// by every capture path. Runs on the UNtruncated candidate.
bool _looksLikeName(String candidate) {
  if (candidate.isEmpty || candidate.length > 40) return false;
  if (candidate.contains(RegExp(r'[0-9]'))) return false;
  final tokens = candidate.split(' ').where((t) => t.isNotEmpty).toList();
  if (tokens.isEmpty || tokens.length > 3) return false;
  for (var i = 0; i < tokens.length; i++) {
    final tok = tokens[i];
    if (!_nameTokenRe.hasMatch(tok)) return false;
    final low = foldAccents(tok.toLowerCase());
    // A particle is tolerated mid-name only.
    if (i > 0 && _nameParticles.contains(low)) continue;
    if (_notNameWords.contains(low)) return false;
  }
  return true;
}

/// True when every token of [candidate] starts with an uppercase letter in the
/// ORIGINAL text — the proper-name signal the weak-prefix path requires.
bool _allTokensCapitalized(String candidate) {
  final tokens = candidate.split(' ').where((t) => t.isNotEmpty);
  for (final tok in tokens) {
    final first = tok.substring(0, 1);
    if (first.toLowerCase() == first) return false;
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
