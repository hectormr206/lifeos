// Did the machine understand what you read aloud?
//
// The learner reads a known sentence; Whisper transcribes it; the two are
// aligned word by word with a longest common subsequence. Each target word is
// "heard" when the alignment matches it, and missed otherwise (left out, or
// heard as a different word). Extra words the learner added (a repeat, an
// "um") are not held against them.
//
// What this is NOT: a pronunciation score. With a known text Whisper leans
// towards the right words, so a high score means "understood", never "perfect
// accent". Phoneme-level scoring needs a different model; see the ODD doc.
library;

final RegExp _word = RegExp(r"\p{L}+(?:['’]\p{L}+)?", unicode: true);

/// Lowercase, apostrophes dropped: "Isn't" and "isnt" are the same word to
/// a transcript.
String _normalize(String word) =>
    word.toLowerCase().replaceAll(RegExp(r"['’]"), '');

class ScoredWord {
  const ScoredWord({required this.text, required this.heard});

  /// As written in the target, for display.
  final String text;
  final bool heard;
}

class ReadAloudScore {
  const ReadAloudScore({required this.words, required this.intelligibility});

  final List<ScoredWord> words;

  /// Share of target words heard, 0-1.
  final double intelligibility;
}

ReadAloudScore scoreReadAloud({
  required String target,
  required String transcript,
}) {
  final shown = [for (final m in _word.allMatches(target)) m.group(0)!];
  final a = [for (final w in shown) _normalize(w)];
  final b = [for (final m in _word.allMatches(transcript)) _normalize(m.group(0)!)];

  // lcs[i][j]: longest common subsequence of a[i..] and b[j..].
  final lcs = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  final heard = List.filled(a.length, false);
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      heard[i] = true;
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }

  final hits = heard.where((h) => h).length;
  return ReadAloudScore(
    words: [
      for (var k = 0; k < shown.length; k++)
        ScoredWord(text: shown[k], heard: heard[k]),
    ],
    intelligibility: shown.isEmpty ? 0 : hits / shown.length,
  );
}
