// WHO the conversation is about right now.
//
// Asked for directly: the chat has to follow which person is being talked
// about, and above all must not "guardar cosas de una persona en otra".
//
// That last part is the whole reason this file exists. Telling Axi about
// Juan's daughter and having it stored against Laura is not a small bug: the
// app's promise is that it remembers your people correctly, and a memory that
// quietly mixes two people up is worse than one that forgot.
//
// THE DECISION LIVES IN DART, not in a prompt. A ~2B model loses the thread
// within a few turns, and this project has already spent two rounds learning
// that a rule added to a prompt breaks the previous one. Tracking a subject is
// bookkeeping, and bookkeeping belongs in code.
//
// AND IT REFUSES TO GUESS. When the subject is not clear the answer is null,
// which means "ask who this is about" — never "assume the last one". A
// confident wrong attribution is the failure mode this is built to prevent.
library;

import '../../memory/domain/subject.dart' show foldAccents;

/// How long a subject survives without being named again.
///
/// Long enough to tell a story about someone across several messages, short
/// enough that coming back after lunch does not attribute a new person's life
/// to the last one discussed.
const Duration kSubjectWindow = Duration(minutes: 15);

/// The person the conversation is about, and when that was last established.
class ConversationSubject {
  const ConversationSubject({
    required this.name,
    required this.at,
    this.isQuestion = false,
  });

  final String name;

  /// When this subject was last confirmed — by being named, or by a follow-up
  /// that clearly continued it. Refreshed on every turn that keeps the thread,
  /// or a long conversation about one person would go stale mid-story.
  final DateTime at;

  /// True when the turn ASKED about the person rather than saying something
  /// about them. "¿quién es Laura?" is about Laura and must store nothing.
  final bool isQuestion;

  @override
  String toString() => 'ConversationSubject($name, $at, q=$isQuestion)';
}

/// Words that continue a thread without naming anyone.
const Set<String> _pronouns = {
  'el', 'ella', 'ellos', 'ellas', 'su', 'sus', 'le', 'les', 'lo', 'la',
  'he', 'she', 'they', 'his', 'her', 'their',
};

/// Everyday words that start a sentence with a capital and name nobody.
const Set<String> _notNames = {
  'el', 'la', 'los', 'las', 'un', 'una', 'mi', 'tu', 'su', 'y', 'o', 'pero',
  'que', 'quien', 'quienes', 'como', 'cuando', 'donde', 'porque', 'si', 'no',
  'hoy', 'ayer', 'manana', 'ahora', 'luego', 'tambien', 'ademas', 'ya',
  'me', 'te', 'se', 'nos', 'lo', 'le', 'este', 'esta', 'esto', 'ese', 'esa',
  'aqui', 'alli', 'alla', 'muy', 'mas', 'menos', 'bien', 'mal', 'creo',
  'conoci', 'tengo', 'tiene', 'hay', 'es', 'son', 'era', 'fue',
  'the', 'and', 'but', 'who', 'what', 'when', 'where', 'why', 'i', 'my',
  'today', 'yesterday', 'tomorrow', 'now', 'also', 'he', 'she',
};

/// Every capitalised word that reads as a person's name.
List<String> namesIn(String message) {
  final words = RegExp(r"[\p{L}][\p{L}']*", unicode: true)
      .allMatches(message)
      .map((m) => m.group(0)!)
      .toList();
  final names = <String>[];
  for (var i = 0; i < words.length; i++) {
    final word = words[i];
    if (word.length < 2) continue;
    final first = word[0];
    if (first.toUpperCase() != first || first.toLowerCase() == first) continue;
    if (_notNames.contains(foldAccents(word.toLowerCase()))) continue;
    if (!names.contains(word)) names.add(word);
  }
  return names;
}

/// The person this turn is about, or null when it is not clear.
///
/// Null is a real answer and the caller must honour it: ask, do not store.
ConversationSubject? resolveConversationSubject({
  required String message,
  required List<String> knownPeople,
  required DateTime now,
  ConversationSubject? previous,
}) {
  final isQuestion = RegExp(r'[?¿]').hasMatch(message);
  final mentioned = namesIn(message);

  String? canonical(String typed) {
    for (final person in knownPeople) {
      if (foldAccents(person.toLowerCase()) ==
          foldAccents(typed.toLowerCase())) {
        return person;
      }
    }
    return null;
  }

  // People we already know about are the strongest signal, and they are also
  // the only capitalised words we can be SURE name a person. Everything else
  // capitalised might be a city, a company or a Monday.
  final recognised = <String>[
    for (final m in mentioned)
      if (canonical(m) != null) canonical(m)!,
  ];

  // More than one person named: genuinely ambiguous. "Juan me contó que Laura
  // se casa" is about either of them, and picking one silently is exactly how
  // a fact lands on the wrong person.
  if (recognised.length > 1) return null;
  if (recognised.length == 1) {
    // The KNOWN spelling, so "Sofia" typed on a phone keyboard does not become
    // a second person next to "Sofía".
    return ConversationSubject(
        name: recognised.first, at: now, isQuestion: isQuestion);
  }

  final threadIsWarm =
      previous != null && now.difference(previous.at) <= kSubjectWindow;

  // No known person named. A turn that leans on the thread ("él trabaja en
  // Puebla") stays with whoever it was about: "Puebla" is capitalised and
  // names nobody, and attributing a life to a city is the same class of
  // mistake as attributing it to the wrong friend.
  if (threadIsWarm && continuesThread(message)) {
    return ConversationSubject(
        name: previous.name, at: now, isQuestion: isQuestion);
  }

  // Exactly one unfamiliar name and nothing pulling back to the thread: this
  // is how meeting someone new looks.
  if (mentioned.length == 1) {
    return ConversationSubject(
        name: mentioned.first, at: now, isQuestion: isQuestion);
  }
  if (mentioned.length > 1) return null;

  // Nobody named. The thread continues only if it is still warm.
  if (previous == null) return null;
  if (now.difference(previous.at) > kSubjectWindow) return null;

  return ConversationSubject(
      name: previous.name, at: now, isQuestion: isQuestion);
}

/// True when a turn leans on a previous subject instead of naming one.
bool continuesThread(String message) {
  final words = foldAccents(message.toLowerCase())
      .split(RegExp(r'[^\p{L}]+', unicode: true));
  return words.any(_pronouns.contains);
}

/// What to ask when the subject is unclear.
///
/// Naming the candidates matters: "¿de quién hablas?" makes someone repeat
/// themselves, while "¿de Juan o de Laura?" is answered with one word.
String askWhoThisIsAbout(List<String> candidates) {
  if (candidates.isEmpty) return '¿De quién me estás hablando?';
  if (candidates.length == 1) return '¿Esto es sobre ${candidates.first}?';
  final last = candidates.last;
  final rest = candidates.sublist(0, candidates.length - 1).join(', ');
  return '¿Esto es sobre $rest o sobre $last?';
}

/// Put the subject's NAME into a follow-up that leans on the thread.
///
/// The capture layer reads a sentence and stores what it says. "tiene dos
/// hijos" says nothing about whose children they are, so the fact either gets
/// dropped or attached to whoever is handy. Naming the subject before the
/// sentence is read fixes that without touching the capture rules at all.
///
/// Returns the message unchanged whenever there is nothing certain to add:
/// unattributed is recoverable, misattributed is not, because nobody goes
/// looking for a fact filed under the wrong person.
String attributeToSubject(String message, ConversationSubject? subject) {
  if (subject == null || subject.isQuestion) return message;
  final trimmed = message.trim();
  if (trimmed.isEmpty) return message;

  // Already about them by name: leave it exactly as the user wrote it.
  if (namesIn(trimmed)
      .any((n) => foldAccents(n.toLowerCase()) ==
          foldAccents(subject.name.toLowerCase()))) {
    return message;
  }

  // "su esposa se llama Marta" -> "la esposa de Juan se llama Marta". Dropping
  // the possessive instead would produce "Juan esposa se llama Marta", which
  // is stored and later read back at the user.
  final possessive = RegExp(r'^\s*(su|sus)\s+(\S+)\s*', caseSensitive: false);
  final match = possessive.firstMatch(trimmed);
  if (match != null) {
    final noun = match.group(2)!;
    final rest = trimmed.substring(match.end);
    return 'la $noun de ${subject.name} $rest'.trim();
  }

  // A leading pronoun is REPLACED, never doubled: "él Juan trabaja" is
  // nonsense to store and to read back.
  final pronoun = RegExp(
      r'^\s*(él|el|ella|ellos|ellas|he|she|they)\s+',
      caseSensitive: false,
      unicode: true);
  if (pronoun.hasMatch(trimmed)) {
    return '${subject.name} ${trimmed.replaceFirst(pronoun, '')}';
  }

  return '${subject.name} $trimmed';
}
