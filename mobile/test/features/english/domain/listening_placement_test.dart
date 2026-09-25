// Listening placement: graded dictation, A1 to C1.
//
// The learner hears a sentence and writes what they understood. The score is
// word by word, forgiving small spelling slips: this measures what was HEARD,
// not how it is spelled. Levels go up while at least 75% of the words come
// through; the listening level is the last level passed.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/english/domain/listening_placement.dart';
import 'package:lifeos/features/english/domain/vocab_placement_scoring.dart';

void main() {
  group('the sentences', () {
    test('four per level, from A1 to C1, in order', () {
      expect(listeningLevels, [
        CefrLevel.a1, CefrLevel.a2, CefrLevel.b1, CefrLevel.b2, CefrLevel.c1,
      ]);
      for (final level in listeningLevels) {
        expect(listeningSentences[level], hasLength(4), reason: level.name);
      }
    });

    test('longer and harder as the level goes up', () {
      double meanWords(CefrLevel level) =>
          listeningSentences[level]!
              .map((s) => s.split(' ').length)
              .reduce((a, b) => a + b) /
          4;

      expect(meanWords(CefrLevel.c1), greaterThan(meanWords(CefrLevel.a1)));
    });
  });

  group('scoring what was written', () {
    test('everything heard is 100%', () {
      expect(
        scoreDictation(
            target: 'The shop is next to the bank.',
            typed: 'the shop is next to the bank'),
        1.0,
      );
    });

    test('a small spelling slip still counts as heard', () {
      expect(
        scoreDictation(
            target: 'They received the report.',
            typed: 'They recieved the reprt.'),
        1.0,
      );
    });

    test('a short word must be right: "a" is not "the"', () {
      expect(
        scoreDictation(target: 'I have a dog.', typed: 'I have the dog.'),
        closeTo(3 / 4, 1e-9),
      );
    });

    test('a word not heard at all is missed', () {
      expect(
        scoreDictation(
            target: 'We eat dinner at seven.', typed: 'We eat at seven.'),
        closeTo(4 / 5, 1e-9),
      );
    });
  });

  group('going up the levels', () {
    test('it keeps going while three quarters or more come through', () {
      final session = ListeningPlacement();
      for (var i = 0; i < 4; i++) {
        expect(session.current!.level, CefrLevel.a1);
        session.answer(0.9);
      }
      expect(session.current!.level, CefrLevel.a2);
    });

    test('it stops at the first level not passed, and places below it', () {
      final session = ListeningPlacement();
      for (var i = 0; i < 4; i++) {
        session.answer(1.0); // A1
      }
      for (var i = 0; i < 4; i++) {
        session.answer(0.4); // A2
      }

      expect(session.isFinished, isTrue);
      expect(session.level, CefrLevel.a1);
    });

    test('failing A1 places before A1: no level, said honestly', () {
      final session = ListeningPlacement();
      for (var i = 0; i < 4; i++) {
        session.answer(0.2);
      }

      expect(session.isFinished, isTrue);
      expect(session.level, isNull);
    });

    test('passing everything tops out at C1', () {
      final session = ListeningPlacement();
      while (!session.isFinished) {
        session.answer(1.0);
      }

      expect(session.level, CefrLevel.c1);
    });
  });
}
