// Proves the on-device daily-digest aggregation is deterministic and TODAY-only:
// it filters by the injected `now` (device tz), keeps exact per-record
// timestamps, and groups by domain + person (me / Celia) — never inventing data.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/graph/graph_records.dart';
import 'package:lifeos/core/timezone/effective_timezone.dart';
import 'package:lifeos/features/daily_digest/domain/daily_digest_aggregator.dart';
import 'package:lifeos/features/domains/domain/local_domain_entry.dart';
import 'package:lifeos/features/memory/domain/person_directory.dart';
import 'package:timezone/timezone.dart' as tz;

GraphNodeRecord _person(String uuid, String label, String relation) => GraphNodeRecord(
      uuid: uuid,
      kind: 'person',
      label: label,
      data: {'relation': relation},
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

LocalDomainEntry _entry(String uuid, String label, DateTime ts, {String? subject, String? type}) =>
    LocalDomainEntry(
      uuid: uuid,
      label: label,
      timestamp: ts,
      type: type,
      data: {if (subject != null) 'subject': subject, if (type != null) 'type': type},
    );

void main() {
  // Wednesday 2026-07-22 21:00 (local).
  final now = DateTime(2026, 7, 22, 21);
  final directory = PersonDirectory.fromNodes([_person('p1', 'Celia', 'esposa')]);

  test('keeps only TODAY entries, grouped by domain + person', () {
    final data = aggregateDailyDigest(
      {
        'health': [
          _entry('h1', 'Presión 120/80', DateTime(2026, 7, 22, 8, 30), type: 'blood_pressure'),
          _entry('h2', 'Presión 121/79', DateTime(2026, 7, 22, 9), subject: 'esposa', type: 'blood_pressure'),
          _entry('h3', 'Presión de ayer', DateTime(2026, 7, 21, 9), type: 'blood_pressure'), // excluded
        ],
        'finance': [
          _entry('f1', 'Gasto \$50', DateTime(2026, 7, 22, 12), type: 'expense'),
        ],
        'exercise': const [], // no activity → omitted
      },
      now: now,
      directory: directory,
    );

    expect(data.totalEntries, 3); // yesterday's h3 excluded
    expect(data.sections.map((s) => s.domainKey), ['health', 'finance']);

    final health = data.sections.first;
    expect(health.count, 2);
    // Grouped by person (entries are newest-first, so Celia's 09:00 leads).
    expect(health.people.map((g) => g.personLabel).toSet(), {'Yo', 'Celia'});
    final celia = health.people.firstWhere((g) => g.personLabel == 'Celia');
    final yo = health.people.firstWhere((g) => g.personLabel == 'Yo');
    expect(celia.entries.single.uuid, 'h2');
    expect(yo.entries.single.uuid, 'h1');
    // Exact timestamp preserved.
    expect(celia.entries.single.timestamp, DateTime(2026, 7, 22, 9));
  });

  test('empty when nothing was captured today', () {
    final data = aggregateDailyDigest(
      {
        'health': [_entry('h3', 'Presión de ayer', DateTime(2026, 7, 21, 9), type: 'blood_pressure')],
      },
      now: now,
      directory: directory,
    );
    expect(data.isEmpty, isTrue);
    expect(renderDigestFacts(data), contains('no registraste nada'));
  });

  test('renderDigestFacts lists the person names + exact times', () {
    final data = aggregateDailyDigest(
      {
        'health': [
          _entry('h2', 'Presión 121/79', DateTime(2026, 7, 22, 9, 5), subject: 'esposa', type: 'blood_pressure'),
        ],
      },
      now: now,
      directory: directory,
    );
    final facts = renderDigestFacts(data);
    expect(facts, contains('Salud'));
    expect(facts, contains('Celia'));
    expect(facts, contains('09:05'));
    expect(facts, contains('22/07/2026'));
  });

  group('override zone defines "today" (near-midnight entry lands correctly)', () {
    // now = 18:00 UTC on 2026-07-22 → wall-clock 2026-07-22 in both zones.
    // entry = 05:30 UTC on 2026-07-22:
    //   * Mexico City (UTC-6): 2026-07-21 23:30 → belongs to Jul-21 (NOT today)
    //   * New York   (UTC-4 EDT): 2026-07-22 01:30 → belongs to Jul-22 (today)
    final nowUtc = DateTime.utc(2026, 7, 22, 18);
    final entryUtc = DateTime.utc(2026, 7, 22, 5, 30);
    late tz.Location mexico;
    late tz.Location ny;

    setUpAll(() {
      EffectiveTimezoneResolver.ensureDatabase();
      mexico = tz.getLocation('America/Mexico_City');
      ny = tz.getLocation('America/New_York');
    });

    Map<String, List<LocalDomainEntry>> entries() => {
          'health': [_entry('h1', 'Presión 120/80', entryUtc, type: 'blood_pressure')],
        };

    test('excluded in Mexico City (it was yesterday there)', () {
      final data = aggregateDailyDigest(
        entries(),
        now: nowUtc,
        directory: directory,
        location: mexico,
      );
      expect(data.isEmpty, isTrue);
    });

    test('included in New York (it is today there)', () {
      final data = aggregateDailyDigest(
        entries(),
        now: nowUtc,
        directory: directory,
        location: ny,
      );
      expect(data.totalEntries, 1);
    });
  });
}
