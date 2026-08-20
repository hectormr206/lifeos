// What Axi says when you open the chat, instead of waiting.
//
// Nothing in the app ever started a conversation: everything Axi knew was
// there because the user went and told it. That puts the whole burden on the
// busiest person in the room, and makes the chat a form rather than someone
// who knows you.
//
// This is NOT a notification. It is the first line on the screen, built from
// what is already in the graph, so it can only ever mention something the user
// actually said.
//
// THE LINE IT MUST NOT CROSS: never invent a follow-up. "¿Cómo va la rodilla?"
// is allowed only if a knee was mentioned. An opener about something that
// never happened is the fastest way to make someone stop trusting the memory —
// and unlike a wrong answer, this one arrives unprompted.
library;

/// Something remembered, as far as an opener is concerned.
class OpeningFact {
  const OpeningFact({required this.label, required this.at, this.domain});

  final String label;
  final DateTime at;
  final String? domain;
}

/// Younger than this and they just told you; asking again reads as not having
/// listened.
const int kOpenerMinDays = 2;

/// Older than this and it is not attentive, it is unsettling.
const int kOpenerMaxDays = 21;

/// The line to open with, or null to stay quiet.
///
/// [lastOpener] is what was said the previous time: repeating it is how
/// someone stops opening the chat.
///
/// [lastSpokeAt] is when the conversation last had anything in it. Opening the
/// chat five times in one morning must not produce five greetings, and this
/// uses a fact that already exists rather than a counter that has to be kept
/// in sync.
String? openingLine(
  List<OpeningFact> facts, {
  required DateTime now,
  String? lastOpener,
  DateTime? lastSpokeAt,
}) {
  if (lastSpokeAt != null && now.difference(lastSpokeAt).inHours < 20) {
    return null;
  }
  final candidates = [
    for (final fact in facts)
      if (fact.label.trim().isNotEmpty) fact,
  ]..sort((a, b) => b.at.compareTo(a.at));

  for (final fact in candidates) {
    final days = now.difference(fact.at).inDays;
    if (days < kOpenerMinDays || days > kOpenerMaxDays) continue;

    // The user's OWN words, quoted. A paraphrase is where an invented detail
    // sneaks in, and this line is read before anyone has asked for anything.
    final line = 'La última vez me dijiste: "${fact.label.trim()}". '
        '¿Cómo va eso?';
    if (line == lastOpener) continue;
    return line;
  }
  return null;
}
