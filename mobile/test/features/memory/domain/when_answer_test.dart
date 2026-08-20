// "¿A qué hora?" is answered from the graph, never by the model.
//
// Measured on the test Pixel with 881, the first build that gave the model
// times at all:
//
//     recorded:  peso 82 kg · 18/08/2026 09:16
//     Axi said:  "Ayer pesaste 82 kg a las 15:16."
//
// The weight was right and the hour was invented — it looks like a blend of
// 09:16 and another entry's 15:37. That is exactly the failure this codebase
// has hit twice before: a ~2B model handed a specific value repeats a
// plausible neighbour instead. Kinship was moved into Dart for the same
// reason.
//
// A wrong hour is not a rounding error. "Te tomaste la pastilla a las 15:00"
// when it was 09:00 is the kind of thing someone acts on.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/when_answer.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

void main() {
  group('recognising the question', () {
    test('"¿a qué hora me pesé?" is one', () {
      expect(asksAboutTime('¿a qué hora me pesé?'), isTrue);
    });

    test('without accents too, because phones', () {
      expect(asksAboutTime('a que hora me pese ayer'), isTrue);
    });

    test('"cuándo" counts as well', () {
      expect(asksAboutTime('¿cuándo me tomé la pastilla?'), isTrue);
    });

    test('an ordinary question is not', () {
      expect(asksAboutTime('¿cuánto pesé ayer?'), isFalse);
      expect(asksAboutTime('¿quién es Laura?'), isFalse);
    });

    test('English installs are recognised', () {
      expect(asksAboutTime('what time did I weigh myself?'), isTrue);
    });
  });

  group('answering it', () {
    final facts = [
      (label: 'peso 82 kg', at: DateTime(2026, 8, 18, 9, 16)),
      (label: 'presión 118/78', at: DateTime(2026, 8, 19, 12, 41)),
    ];

    test('one candidate gives the exact time, straight from the record', () {
      final answer = answerAboutTime(
        question: '¿a qué hora me pesé?',
        facts: facts,
        languageCode: 'es',
      );

      expect(answer, contains('09:16'));
      expect(answer, contains('peso 82 kg'));
    });

    test('it never rounds or approximates', () {
      final answer = answerAboutTime(
        question: 'a qué hora me pesé',
        facts: facts,
        languageCode: 'es',
      );

      expect(answer, isNot(contains('9:00')));
      expect(answer!.toLowerCase(), isNot(contains('como a las')));
    });

    test('nothing matching means the model answers, not a guess', () {
      // Null hands the turn back. Better an ordinary reply than a confident
      // hour about something that was never recorded.
      expect(
        answerAboutTime(
          question: '¿a qué hora corrí?',
          facts: facts,
          languageCode: 'es',
        ),
        isNull,
      );
    });

    test('two candidates are listed, not merged into one', () {
      // Merging is precisely how 09:16 and 15:37 became "15:16".
      final answer = answerAboutTime(
        question: '¿a qué hora me tomé la presión?',
        facts: [
          (label: 'presión 118/78', at: DateTime(2026, 8, 19, 7, 5)),
          (label: 'presión 130/85', at: DateTime(2026, 8, 19, 22, 40)),
        ],
        languageCode: 'es',
      );

      expect(answer, contains('07:05'));
      expect(answer, contains('22:40'));
    });

    test('a fact with no real time is not answered with midnight', () {
      expect(
        answerAboutTime(
          question: '¿a qué hora fue el aniversario?',
          facts: [(label: 'aniversario', at: DateTime(2026, 8, 18))],
          languageCode: 'es',
        ),
        isNull,
      );
    });

    test('English answers in English', () {
      final answer = answerAboutTime(
        question: 'what time did I weigh myself?',
        facts: [(label: 'weight 82 kg', at: DateTime(2026, 8, 18, 9, 16))],
        languageCode: 'en',
      );

      expect(answer, contains('09:16'));
    });
  });

  group('the hour is the USER\'s hour', () {
    // Same bug as the recall block: the graph stores UTC, and printing the raw
    // hour reported 15:16 for something logged at 09:16 in Mexico City. Right
    // instant, wrong zone — which for a person reading it is just the wrong
    // time.
    setUpAll(tzdata.initializeTimeZones);

    test('a UTC instant is answered in the configured zone', () {
      final answer = answerAboutTime(
        question: '¿a qué hora me pesé?',
        // 09:16 in Mexico City.
        facts: [(label: 'peso 82 kg', at: DateTime.utc(2026, 8, 18, 15, 16))],
        languageCode: 'es',
        location: tz.getLocation('America/Mexico_City'),
      );

      expect(answer, contains('09:16'));
      expect(answer, isNot(contains('15:16')));
    });

    test('with no zone it falls back to the device, not to UTC', () {
      final answer = answerAboutTime(
        question: '¿a qué hora me pesé?',
        facts: [(label: 'peso 82 kg', at: DateTime.utc(2026, 8, 18, 15, 16))],
        languageCode: 'es',
      );

      expect(answer, isNotNull);
    });
  });

  test('a date-only entry is still skipped once the zone is applied', () {
    // Stored at LOCAL midnight, which is 06:00 UTC in Mexico. Checking the raw
    // value would let it through as if someone had typed a time.
    tzdata.initializeTimeZones();

    expect(
      answerAboutTime(
        question: '¿a qué hora fue el aniversario?',
        facts: [(label: 'aniversario', at: DateTime.utc(2026, 8, 18, 6))],
        languageCode: 'es',
        location: tz.getLocation('America/Mexico_City'),
      ),
      isNull,
    );
  });
}

