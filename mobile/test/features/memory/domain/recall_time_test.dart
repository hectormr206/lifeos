// The HOUR reaches the model, when there is one.
//
// The block grouped by day and threw the time away, so the app could show
// "peso 82 kg · 18/08/2026 09:16" on screen while Axi, asked "¿a qué hora me
// pesé?", had no idea. The data was there and the answer was not.
//
// It matters beyond curiosity: a blood-pressure reading at 07:00 and one at
// 23:00 are different readings, and "me tomé la pastilla" twice in one day is
// two different facts only if you can see when.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/recall_block.dart';

void main() {
  final now = DateTime(2026, 8, 19, 18);

  RecallFact fact(String label, DateTime at) =>
      RecallFact(label: label, occurredAt: at, createdAt: at);

  group('times that exist are passed on', () {
    test('a fact with a real time carries it', () {
      final block = buildRecallBlock(
        '',
        [fact('peso 82 kg', DateTime(2026, 8, 18, 9, 16))],
        now: now,
      );

      expect(block, contains('09:16'));
    });

    test('several in a day keep their own times', () {
      final block = buildRecallBlock(
        '',
        [
          fact('presión 118/78', DateTime(2026, 8, 19, 7, 5)),
          fact('presión 130/85', DateTime(2026, 8, 19, 22, 40)),
        ],
        now: now,
      );

      expect(block, contains('07:05'));
      expect(block, contains('22:40'));
    });

    test('the day is still there, not replaced by the time', () {
      final block = buildRecallBlock(
        '',
        [fact('peso 82 kg', DateTime(2026, 8, 18, 9, 16))],
        now: now,
      );

      expect(block, contains('18 de agosto'));
    });
  });

  group('times that do NOT exist are not invented', () {
    test('a date-only entry shows no time', () {
      // Date-only fields (a birthday, an anniversary) are stored at midnight.
      // Printing "00:00" would be inventing a precision nobody entered, and
      // the model would repeat it back as if it meant something.
      final block = buildRecallBlock(
        '',
        [fact('aniversario', DateTime(2026, 8, 18))],
        now: now,
      );

      expect(block, isNot(contains('00:00')));
    });

    test('an undated fact is still marked as undated', () {
      final block = buildRecallBlock(
        '',
        [
          RecallFact(label: 'algo sin fecha', createdAt: DateTime(2026, 8, 18)),
        ],
        now: now,
      );

      expect(block.toLowerCase(), contains('sin fecha'));
      // No CLOCK time — the header's colon does not count.
      expect(RegExp(r'\d{2}:\d{2}').hasMatch(block), isFalse);
    });
  });

  group('a question about a day only brings back that day', () {
    // The point of parsing the date at all: "¿qué anoté el martes?" used to
    // search by words and bring back whatever mentioned "martes".

    final week = [
      fact('peso 82 kg', DateTime(2026, 8, 18, 9, 16)),
      fact('presión 118/78', DateTime(2026, 8, 19, 7, 0)),
      fact('corrí 5 km', DateTime(2026, 8, 17, 19, 30)),
    ];

    test('"ayer" leaves out today and the day before', () {
      final block = buildRecallBlock('¿qué anoté ayer?', week, now: now);

      expect(block, contains('peso 82 kg'));
      expect(block, isNot(contains('presión')));
      expect(block, isNot(contains('corrí')));
    });

    test('"el lunes" finds the entry from that Monday', () {
      final block = buildRecallBlock('qué hice el lunes', week, now: now);

      expect(block, contains('corrí 5 km'));
    });

    test('a question with no date still sees everything', () {
      // The behaviour that must not change: no time expression, no window.
      final block = buildRecallBlock('cómo voy', week, now: now);

      expect(block, contains('peso 82 kg'));
      expect(block, contains('presión'));
    });

    test('a day with nothing in it comes back EMPTY, not with other days', () {
      // The dangerous failure: answering "el jueves" with Wednesday's data
      // and letting the model present it as Thursday's.
      final block = buildRecallBlock('qué anoté el jueves', week, now: now);

      expect(block, isEmpty);
    });
  });
}

