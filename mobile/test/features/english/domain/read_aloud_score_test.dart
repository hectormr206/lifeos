// Did the machine understand what you read aloud?
//
// The learner reads a known sentence; Whisper transcribes it; the two are
// aligned word by word. Each target word is heard or missed, and the score is
// the share heard. It measures intelligibility, not pronunciation: with a
// known text Whisper leans towards the right words, so a high score means
// "understood", never "perfect accent".
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/read_aloud_score.dart';

List<bool> heard(ReadAloudScore s) => [for (final w in s.words) w.heard];

void main() {
  test('reading it exactly is fully understood', () {
    final score = scoreReadAloud(
      target: 'Dogs sniff the ground.',
      transcript: 'dogs sniff the ground',
    );

    expect(score.intelligibility, 1.0);
    expect(heard(score), [true, true, true, true]);
  });

  test('case and punctuation do not count against you', () {
    final score = scoreReadAloud(
      target: "It's a dog's life, isn't it?",
      transcript: 'its a dogs life isnt it',
    );

    expect(score.intelligibility, 1.0);
  });

  test('a word heard as another one is marked, and only that one', () {
    final score = scoreReadAloud(
      target: 'I live in a big city.',
      transcript: 'I leave in a big city.',
    );

    expect(heard(score), [true, false, true, true, true, true]);
    expect(score.words[1].text, 'live');
    expect(score.intelligibility, closeTo(5 / 6, 1e-9));
  });

  test('a word left out is missed', () {
    final score = scoreReadAloud(
      target: 'The cat is on the table.',
      transcript: 'The cat on the table.',
    );

    expect(heard(score), [true, true, false, true, true, true]);
  });

  test('extra words the learner added do not lower the score', () {
    final score = scoreReadAloud(
      target: 'The cat sleeps.',
      transcript: 'The the cat um sleeps.',
    );

    expect(score.intelligibility, 1.0);
  });

  test('nothing understood is zero, not an error', () {
    final score = scoreReadAloud(target: 'The cat sleeps.', transcript: '');

    expect(score.intelligibility, 0);
    expect(heard(score), [false, false, false]);
  });

  test('the words keep their original spelling for display', () {
    final score = scoreReadAloud(target: 'Hello, World!', transcript: 'hello');

    expect(score.words.map((w) => w.text), ['Hello', 'World']);
  });
}
