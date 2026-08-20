// "¿A qué hora?" — answered from the record, never by the model.
//
// Measured on the test Pixel with 881, the first build that gave the model
// times at all:
//
//     recorded:  peso 82 kg · 18/08/2026 09:16
//     Axi said:  "Ayer pesaste 82 kg a las 15:16."
//
// The weight was right and the hour was invented — a blend of 09:16 and
// another entry's 15:37. Handing a small model a specific value and hoping it
// copies it exactly is a bet this project has now lost three times: the
// kinship answers moved into Dart for the same reason, after four rounds of
// prompt rules each broke the last.
//
// A wrong hour is not a rounding error. "Te tomaste la pastilla a las 15:00"
// when it was 09:00 is something a person acts on.
//
// IT ANSWERS ONLY WHEN THE RECORD SAYS SO. No match, or no real time, returns
// null and the model handles the turn as it always did — an ordinary reply
// beats a confident hour about something that was never written down.
library;

import 'subject.dart' show foldAccents;

/// One remembered thing and when it happened.
typedef TimedFact = ({String label, DateTime at});

/// True when the turn asks WHEN something happened.
bool asksAboutTime(String message) {
  final text = foldAccents(message.toLowerCase());
  return RegExp(r'\ba\s+que\s+hora\b').hasMatch(text) ||
      RegExp(r'\bcuando\b').hasMatch(text) ||
      RegExp(r'\bwhat\s+time\b').hasMatch(text) ||
      RegExp(r'\bwhen\s+did\b').hasMatch(text);
}

/// Words that carry no clue about WHICH fact is being asked after.
const Set<String> _noise = {
  'a', 'que', 'hora', 'cuando', 'me', 'mi', 'el', 'la', 'los', 'las', 'de',
  'del', 'fue', 'ayer', 'hoy', 'anteayer', 'yo', 'lo', 'se', 'tome', 'tomo',
  'hice', 'hizo', 'anoche', 'what', 'time', 'did', 'i', 'when', 'the',
  'my', 'was', 'is',
};

/// The answer, or null to let the model handle it.
String? answerAboutTime({
  required String question,
  required List<TimedFact> facts,
  required String languageCode,
}) {
  if (!asksAboutTime(question)) return null;

  final asked = foldAccents(question.toLowerCase())
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((w) => w.length > 2 && !_noise.contains(w))
      .toSet();
  if (asked.isEmpty) return null;

  final matches = <TimedFact>[];
  for (final fact in facts) {
    // Midnight means date-only — a birthday or an anniversary. Answering
    // "a las 00:00" would be inventing a precision nobody entered.
    if (fact.at.hour == 0 && fact.at.minute == 0) continue;
    final words = foldAccents(fact.label.toLowerCase())
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .toSet();
    // Matched by STEM, not by exact word: the question says "pesé" and the
    // record says "peso", "corrí" against "correr". Three characters, with
    // both words at least four long — enough for the conjugation to fall off,
    // short enough that it does not start matching unrelated words in the
    // handful of facts a query already narrowed down.
    if (words.any((w) => asked.any((q) => _sameStem(w, q)))) {
      matches.add(fact);
    }
  }
  if (matches.isEmpty) return null;

  matches.sort((a, b) => a.at.compareTo(b.at));
  final en = languageCode == 'en';
  String at(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // Listed, never merged: merging is precisely how 09:16 and 15:37 became
  // "15:16".
  final lines = [
    for (final m in matches)
      en ? '${m.label} at ${at(m.at)}' : '${m.label} a las ${at(m.at)}',
  ];
  return lines.join('; ') + (en ? '.' : '.');
}


/// True when two words share a stem long enough to be the same idea.
bool _sameStem(String a, String b) {
  if (a.length < 4 || b.length < 4) return a == b;
  return a.substring(0, 3) == b.substring(0, 3);
}
