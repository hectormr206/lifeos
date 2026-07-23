import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/recall_block.dart';

/// SLICE A3 — pure recall-block formatter.
void main() {
  group('buildRecallBlock', () {
    test('empty facts -> empty string', () {
      expect(buildRecallBlock('presión', const []), '');
    });

    test('buckets by day with ES header and month names', () {
      final block = buildRecallBlock(
        'presión',
        [
          RecallFact(label: 'presión 110/81', occurredAt: DateTime(2026, 7, 20)),
          RecallFact(label: 'pulso 51', occurredAt: DateTime(2026, 7, 20)),
          RecallFact(label: 'gasté 450', occurredAt: DateTime(2026, 7, 19)),
        ],
        now: DateTime(2026, 7, 22),
      );
      expect(block, contains('MEMORIA RELEVANTE'));
      expect(block, contains('El 20 de julio de 2026: presión 110/81; pulso 51'));
      expect(block, contains('El 19 de julio de 2026: gasté 450'));
    });

    test('marks today explicitly', () {
      final block = buildRecallBlock(
        'x',
        [RecallFact(label: 'hoy comí', occurredAt: DateTime(2026, 7, 22))],
        now: DateTime(2026, 7, 22),
      );
      expect(block, contains('HOY (22 de julio de 2026)'));
    });

    test('EN header + month names', () {
      final block = buildRecallBlock(
        'pressure',
        [RecallFact(label: 'pressure 110/81', occurredAt: DateTime(2026, 7, 20))],
        en: true,
        now: DateTime(2026, 7, 22),
      );
      expect(block, contains('RELEVANT MEMORY'));
      expect(block, contains('On July 20, 2026'));
    });

    test('dedupes identical labels within a day', () {
      final block = buildRecallBlock(
        'x',
        [
          RecallFact(label: 'presión 110/81', occurredAt: DateTime(2026, 7, 20)),
          RecallFact(label: 'presión 110/81', occurredAt: DateTime(2026, 7, 20)),
        ],
        now: DateTime(2026, 7, 22),
      );
      expect('presión 110/81'.allMatches(block).length, 1);
    });

    test('undated facts go under a "sin fecha" group, never dated', () {
      final block = buildRecallBlock(
        'x',
        [RecallFact(label: 'esposa: Ana', createdAt: DateTime(2026, 7, 1))],
        now: DateTime(2026, 7, 22),
      );
      expect(block, contains('Sin fecha de medición'));
      expect(block, contains('esposa: Ana'));
    });

    test('caps total facts across days', () {
      final block = buildRecallBlock(
        'x',
        List.generate(
          10,
          (i) => RecallFact(label: 'f$i', occurredAt: DateTime(2026, 7, 20)),
        ),
        maxTotalFacts: 3,
        maxLabelsPerDay: 6,
        now: DateTime(2026, 7, 22),
      );
      // Only 3 of the 10 labels survive the total cap.
      final emitted = List.generate(10, (i) => 'f$i')
          .where((f) => block.contains(f))
          .length;
      expect(emitted, 3);
    });
  });

  group('subject attribution', () {
    test('self query drops a family-tagged health fact', () {
      final block = buildRecallBlock(
        'mi presión',
        [
          RecallFact(
            label: 'esposa presión 121/79',
            occurredAt: DateTime(2026, 7, 20),
            domain: 'health',
            subject: 'esposa',
          ),
        ],
        now: DateTime(2026, 7, 22),
      );
      expect(block, ''); // family fact filtered out for a self query
    });

    test('query naming the member surfaces that member\'s fact', () {
      final block = buildRecallBlock(
        'la presión de mi esposa',
        [
          RecallFact(
            label: 'presión 121/79',
            occurredAt: DateTime(2026, 7, 20),
            domain: 'health',
            subject: 'esposa',
          ),
        ],
        now: DateTime(2026, 7, 22),
      );
      expect(block, contains('presión 121/79'));
    });
  });
}
