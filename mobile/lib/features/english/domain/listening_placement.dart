// Listening placement: graded dictation, A1 to C1.
//
// "Place first, per skill" (ODD doc): the vocabulary test says what the
// learner recognises when reading, not what they catch by ear, and the two
// often differ a lot. So the learner hears sentences with an English voice,
// four per level, and writes what they understood.
//
// The score is word by word (the same alignment as reading aloud), forgiving
// small spelling slips in longer words ("recieved" is "received"): this
// measures what was HEARD, not spelling. A short word must be right, because
// "a" for "the" is a listening miss. Levels go up while at least 75% of the
// words come through; the listening level is the last one passed, or none
// before A1, said as such. C1 is the top this measures.
//
// The sentences were written for this test: everyday at A1-A2, work and
// plans at B1, reported and conditional structures at B2, formal register
// at C1.
library;

import 'read_aloud_score.dart';
import 'vocab_placement_scoring.dart';

/// Share of words that must come through to pass a level.
const double kListeningPass = 0.75;

const List<CefrLevel> listeningLevels = [
  CefrLevel.a1,
  CefrLevel.a2,
  CefrLevel.b1,
  CefrLevel.b2,
  CefrLevel.c1,
];

const Map<CefrLevel, List<String>> listeningSentences = {
  CefrLevel.a1: [
    'My name is Anna and I live in a small house.',
    'I have two brothers and one sister.',
    'We eat dinner at seven every day.',
    'The shop is next to the bank.',
  ],
  CefrLevel.a2: [
    'Last weekend we went to the beach with our friends.',
    'Could you tell me where the train station is?',
    'I usually take the bus to work because it is cheaper.',
    'She has been learning to cook since last year.',
  ],
  CefrLevel.b1: [
    'If the weather is good tomorrow, we might go hiking in the mountains.',
    'The meeting was postponed because the manager was stuck in traffic.',
    'I would rather work from home than spend two hours commuting.',
    'They asked us to send the report before the end of the week.',
  ],
  CefrLevel.b2: [
    'Despite the delays, the project was delivered within the original budget.',
    'Had we known about the changes earlier, we would have planned differently.',
    'The new policy is expected to have a significant impact on small businesses.',
    'It is widely assumed that remote work reduces productivity, but the '
        'evidence is mixed.',
  ],
  CefrLevel.c1: [
    "The committee's reluctance to endorse the proposal stemmed largely from "
        'concerns about its long-term viability.',
    'Notwithstanding the initial setbacks, the initiative has garnered '
        'considerable support among stakeholders.',
    'Her argument, while compelling on the surface, overlooks several crucial '
        'nuances.',
    'The findings underscore the need for a more rigorous approach to data '
        'collection.',
  ],
};

final RegExp _word = RegExp(r"\p{L}+(?:['’]\p{L}+)?", unicode: true);

String _norm(String w) => w.toLowerCase().replaceAll(RegExp(r"['’]"), '');

/// Optimal string alignment distance: edits plus adjacent swaps, so
/// "recieved" is one step from "received".
int _distance(String a, String b) {
  final d = List.generate(a.length + 1, (i) => List.filled(b.length + 1, 0));
  for (var i = 0; i <= a.length; i++) {
    d[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    d[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      var best = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost]
          .reduce((x, y) => x < y ? x : y);
      if (i > 1 &&
          j > 1 &&
          a[i - 1] == b[j - 2] &&
          a[i - 2] == b[j - 1] &&
          d[i - 2][j - 2] + 1 < best) {
        best = d[i - 2][j - 2] + 1;
      }
      d[i][j] = best;
    }
  }
  return d[a.length][b.length];
}

/// Share of [target]'s words that came through in what was [typed].
double scoreDictation({required String target, required String typed}) {
  final targetWords = {for (final m in _word.allMatches(target)) _norm(m.group(0)!)};
  final heard = [
    for (final m in _word.allMatches(typed))
      _closest(_norm(m.group(0)!), targetWords),
  ].join(' ');
  return scoreReadAloud(target: target, transcript: heard).intelligibility;
}

/// A typed word, or the target word it is a small spelling slip of.
String _closest(String typed, Set<String> targets) {
  if (targets.contains(typed) || typed.length < 4) return typed;
  for (final t in targets) {
    if (t.length >= 4 && _distance(typed, t) <= 1) return t;
  }
  return typed;
}

class ListeningItem {
  const ListeningItem({required this.level, required this.sentence});

  final CefrLevel level;
  final String sentence;
}

/// Runs the dictation level by level.
class ListeningPlacement {
  ListeningPlacement()
      : _items = [
          for (final level in listeningLevels)
            for (final s in listeningSentences[level]!)
              ListeningItem(level: level, sentence: s),
        ];

  final List<ListeningItem> _items;
  final List<double> _levelScores = [];
  int _index = 0;
  bool _finished = false;
  CefrLevel? _passed;

  ListeningItem? get current => _finished ? null : _items[_index];
  bool get isFinished => _finished;

  /// The last level passed; null when A1 was not (before A1).
  CefrLevel? get level => _passed;

  /// Records the dictation score (0-1) of the current sentence.
  void answer(double score) {
    if (_finished) {
      throw StateError('The listening placement is over.');
    }
    final item = _items[_index];
    _levelScores.add(score);
    _index++;
    final levelOver = _index == _items.length || _items[_index].level != item.level;
    if (!levelOver) return;

    final mean = _levelScores.reduce((a, b) => a + b) / _levelScores.length;
    _levelScores.clear();
    if (mean >= kListeningPass) {
      _passed = item.level;
      if (_index == _items.length) _finished = true;
    } else {
      _finished = true;
    }
  }
}
