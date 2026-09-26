// Getting ready for a real conversation, and learning from it afterwards.
//
// From B1 on, people are what the app cannot replace, and the plan says so.
// What it can do is the before and the after:
//   * BEFORE: from the learner's own description of the situation, a few
//     useful phrases at their level and the questions they will probably
//     hear; then a rehearsal where the model plays the other person and
//     opens with one of those questions;
//   * AFTER: the learner writes each thing they wanted to say and could not
//     ("que el proyecto se retrasó..."), one per line, and gets how to say
//     it to the other person in natural English, ready to keep for review.
// A first "after" asked the model to find what to fix in free notes. Against
// the real Gemma E2B it translated the notes themselves, invented items and
// ignored "NOTHING", so it became one narrow task per thing, like the gloss.
library;

import 'practice.dart';
import 'vocab_placement_scoring.dart';

const int kMaxPrepPhrases = 5;
const int kMaxPrepQuestions = 3;
const int kMaxRephrases = 3;
const int _maxRephraseChars = 200;

class Prep {
  const Prep({required this.phrases, required this.questions});

  /// Things the learner can say, in simple English for their level.
  final List<String> phrases;

  /// Questions the other person will probably ask.
  final List<String> questions;
}

String buildPrepPrompt({required String situation, required CefrLevel level}) =>
    'You help a Spanish speaker get ready for a real conversation in '
    'English.\n'
    'The situation, in their words: $situation\n'
    'Their English level: CEFR ${level.name.toUpperCase()}. Use simple, '
    'natural English for that level.\n'
    'Write exactly this and nothing else:\n'
    'five lines that start with "PHRASE:", each a useful sentence they can '
    'say in this situation;\n'
    'then three lines that start with "QUESTION:", each a question the other '
    'person will probably ask them.';

final RegExp _line = RegExp(r'^\s*(PHRASE|QUESTION)\s*:\s*(.+)$');
final RegExp _quotes = RegExp(r'^["“”«»]+|["“”«»]+$');

String _unquote(String s) => s.trim().replaceAll(_quotes, '').trim();

Prep? parsePrep(String answer) {
  final phrases = <String>[];
  final questions = <String>[];
  for (final raw in answer.split('\n')) {
    final m = _line.firstMatch(raw);
    if (m == null) continue;
    final value = _unquote(m.group(2)!);
    if (m.group(1) == 'PHRASE' && phrases.length < kMaxPrepPhrases) {
      phrases.add(value);
    } else if (m.group(1) == 'QUESTION' && questions.length < kMaxPrepQuestions) {
      questions.add(value);
    }
  }
  if (phrases.isEmpty) return null;
  return Prep(phrases: phrases, questions: questions);
}

/// A role-play of the real situation: the model is the other person and
/// opens with the first question the learner prepared for.
RoleplayScenario rehearsalScenario({
  required String situation,
  required Prep prep,
}) =>
    RoleplayScenario(
      id: 'rehearsal',
      title: situation,
      role: 'the other person in this real situation, described by the '
          'learner in Spanish: "$situation". Play them realistically',
      task: situation,
      opening: prep.questions.isNotEmpty ? prep.questions.first : 'Hello!',
    );

/// The things the learner wanted to say: one per non-empty line, at most
/// [kMaxRephrases].
List<String> wantedLines(String text) => [
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ].take(kMaxRephrases).toList();

String buildRephrasePrompt({required String wanted, required String situation}) =>
    'A Spanish speaker had a real conversation in English and could not say '
    'something well.\n'
    'The situation: $situation\n'
    'What they wanted to say, in their words: $wanted\n'
    'Write how to say it in simple, natural spoken English, as one or two '
    'sentences they could say directly to the other person. Answer with the '
    'English only, on one line, with no quotes and no explanation.';

/// The first real line of the answer, unquoted and capped; null when empty.
String? parseRephrase(String answer) {
  for (final raw in answer.split('\n')) {
    final line = _unquote(raw);
    if (line.isEmpty) continue;
    return line.length <= _maxRephraseChars
        ? line
        : line.substring(0, _maxRephraseChars);
  }
  return null;
}
