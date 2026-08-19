// The controls that turn a picture into a tool.
//
// A graph of 88 nodes and 277 relationships cannot be navigated by orbiting it.
// The desktop Cerebro answers with a search box, a domain list and four date
// chips; the phone port shipped with none of them.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/features/brain3d/domain/brain3d_filters.dart';

void main() {
  final now = DateTime(2026, 8, 18, 20);

  GraphNodeRecord node(
    String label, {
    String? domain,
    DateTime? created,
    DateTime? occurred,
  }) =>
      GraphNodeRecord(
        uuid: label,
        kind: 'fact',
        label: label,
        data: const {},
        domain: domain,
        createdAt: created ?? now,
        updatedAt: created ?? now,
        occurredAt: occurred,
      );

  group('searching your memory', () {
    test('finds a memory by part of its text', () {
      final kept = applyBrain3dFilter(
        [node('presión 120/80'), node('peso 82 kg')],
        const Brain3dFilter(query: 'peso'),
        now: now,
      );

      expect(kept.map((n) => n.label), ['peso 82 kg']);
    });

    test('an accent typed or not typed finds the same thing', () {
      // People write "presion" having logged "presión". A search that fails on
      // an accent teaches them the box is broken.
      for (final typed in ['presion', 'presión', 'PRESION']) {
        final kept = applyBrain3dFilter(
          [node('presión 120/80')],
          Brain3dFilter(query: typed),
          now: now,
        );
        expect(kept, hasLength(1), reason: 'typing "$typed" found nothing');
      }
    });

    test('an empty box keeps everything', () {
      final all = [node('a'), node('b')];
      expect(applyBrain3dFilter(all, const Brain3dFilter(), now: now), all);
    });

    test('spaces alone are not a search', () {
      final all = [node('a')];
      expect(applyBrain3dFilter(all, const Brain3dFilter(query: '   '), now: now),
          all);
    });
  });

  group('filtering by domain', () {
    test('keeps only that domain', () {
      final kept = applyBrain3dFilter(
        [node('peso', domain: 'health'), node('Ana', domain: 'relationships')],
        const Brain3dFilter(domain: 'health'),
        now: now,
      );

      expect(kept.map((n) => n.label), ['peso']);
    });

    test('"Todos" keeps every domain, including the ones with none', () {
      final all = [node('a', domain: 'health'), node('b')];
      expect(applyBrain3dFilter(all, const Brain3dFilter(), now: now), all);
    });
  });

  group('filtering by date', () {
    test('"Hoy" means today, not the last 24 hours', () {
      // Something logged at 00:30 is still today at 23:00. A rolling 24-hour
      // window would drop it mid-afternoon for no reason the user can see.
      final kept = applyBrain3dFilter(
        [
          node('madrugada', created: DateTime(2026, 8, 18, 0, 30)),
          node('ayer', created: DateTime(2026, 8, 17, 23, 50)),
        ],
        const Brain3dFilter(range: Brain3dDateRange.today),
        now: now,
      );

      expect(kept.map((n) => n.label), ['madrugada']);
    });

    test('"Esta semana" reaches back seven days', () {
      final kept = applyBrain3dFilter(
        [
          node('hace 3 dias', created: DateTime(2026, 8, 15)),
          node('hace 20 dias', created: DateTime(2026, 7, 29)),
        ],
        const Brain3dFilter(range: Brain3dDateRange.week),
        now: now,
      );

      expect(kept.map((n) => n.label), ['hace 3 dias']);
    });

    test('it filters by when it HAPPENED, not when it was written', () {
      // A blood pressure taken yesterday and logged today belongs to
      // yesterday — that is the date the user remembers.
      final kept = applyBrain3dFilter(
        [
          node('tomada ayer',
              created: now, occurred: DateTime(2026, 8, 17, 9)),
        ],
        const Brain3dFilter(range: Brain3dDateRange.today),
        now: now,
      );

      expect(kept, isEmpty);
    });
  });

  test('the three controls combine', () {
    final kept = applyBrain3dFilter(
      [
        node('peso 82', domain: 'health', created: now),
        node('peso 80', domain: 'health', created: DateTime(2026, 7, 1)),
        node('Ana', domain: 'relationships', created: now),
      ],
      const Brain3dFilter(
        query: 'peso',
        domain: 'health',
        range: Brain3dDateRange.today,
      ),
      now: now,
    );

    expect(kept.map((n) => n.label), ['peso 82']);
  });

  test('an untouched filter reports itself inactive', () {
    // The screen uses this to decide whether to offer "limpiar".
    expect(const Brain3dFilter().isActive, isFalse);
    expect(const Brain3dFilter(query: 'x').isActive, isTrue);
    expect(const Brain3dFilter(domain: 'health').isActive, isTrue);
    expect(const Brain3dFilter(range: Brain3dDateRange.week).isActive, isTrue);
  });
}
