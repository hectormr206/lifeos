// Cutting a passage into tappable words, each knowing its sentence.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/reader_tokens.dart';

void main() {
  test('words and the text between them rebuild the passage exactly', () {
    const text = "Dogs sniff. The cat's food, too!";

    expect(readerTokens(text).map((t) => t.text).join(), text);
  });

  test('only words are tappable', () {
    final words = [
      for (final t in readerTokens('Dogs sniff, a lot.'))
        if (t.isWord) t.text,
    ];

    expect(words, ['Dogs', 'sniff', 'a', 'lot']);
  });

  test('each word knows the sentence it is in', () {
    final tokens = readerTokens('Dogs sniff the ground. Cats sleep.');
    String sentenceOf(String word) =>
        tokens.firstWhere((t) => t.text == word).sentence;

    expect(sentenceOf('sniff'), 'Dogs sniff the ground.');
    expect(sentenceOf('sleep'), 'Cats sleep.');
  });

  test('a line break ends a sentence too', () {
    final tokens = readerTokens('A title\nDogs sniff.');

    expect(tokens.firstWhere((t) => t.text == 'Dogs').sentence, 'Dogs sniff.');
  });

  test('a decimal point does not cut a sentence', () {
    final tokens = readerTokens('It costs 2.50 dollars today.');

    expect(tokens.firstWhere((t) => t.text == 'today').sentence,
        'It costs 2.50 dollars today.');
  });
}
