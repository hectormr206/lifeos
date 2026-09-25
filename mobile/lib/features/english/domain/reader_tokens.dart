// Cutting a passage into tappable words, each knowing its sentence.
//
// The reader shows the passage exactly as written, so the pieces rebuild it
// character for character. Every word carries the sentence it sits in,
// because what a word means is decided by its sentence ("bank" by a river or
// with money), and that sentence is also what gets saved for review.
library;

/// One piece of the passage: a word the learner can tap, or the text between.
class ReaderToken {
  const ReaderToken({
    required this.text,
    required this.isWord,
    required this.sentence,
  });

  final String text;
  final bool isWord;

  /// The sentence around a word; empty for the text between words.
  final String sentence;
}

final RegExp _word = RegExp(r"\p{L}+(?:['’]\p{L}+)?", unicode: true);

/// A sentence ends at . ! ? followed by a space or the end, or at a line
/// break. The point in "2.50" is not an end.
final RegExp _sentence = RegExp(r'[^\n]+?(?:[.!?]+(?=\s|$)|(?=\n)|$)');

List<ReaderToken> readerTokens(String text) {
  final sentences = [
    for (final m in _sentence.allMatches(text))
      if (m.group(0)!.trim().isNotEmpty) m,
  ];
  String sentenceAt(int offset) {
    for (final s in sentences) {
      if (offset >= s.start && offset < s.end) return s.group(0)!.trim();
    }
    return '';
  }

  final tokens = <ReaderToken>[];
  var last = 0;
  for (final m in _word.allMatches(text)) {
    if (m.start > last) {
      tokens.add(ReaderToken(
          text: text.substring(last, m.start), isWord: false, sentence: ''));
    }
    tokens.add(ReaderToken(
        text: m.group(0)!, isWord: true, sentence: sentenceAt(m.start)));
    last = m.end;
  }
  if (last < text.length) {
    tokens.add(ReaderToken(text: text.substring(last), isWord: false, sentence: ''));
  }
  return tokens;
}
