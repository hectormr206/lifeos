// Cross-runtime parity harness (relationships-robustness, Slice 1).
//
// This file and `lifeos/tests/relationships/test_phone_parity.py` load the
// SAME golden fixture (`parity/relationships/cases.json`, at the repo root)
// and assert the phone's `contactsDue`/`upcomingBirthdays` agree byte-for-byte
// with the laptop's `people.due_for_contact`/`people.upcoming_birthdays`.
//
// A behaviour change on either side that is not reflected in the shared
// fixture fails THIS test — drift is loud, never silent (ADR-4, LifeOS
// silent-failure rule). This is a characterization lock: it must be GREEN
// against today's code, not a RED-then-GREEN pair.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/birthdays.dart';
import 'package:lifeos/features/memory/domain/contact_nudge.dart';

/// Locates the golden fixture regardless of whether `flutter test` runs with
/// cwd `mobile/` (the normal case) or the repo root.
File _fixtureFile() {
  for (final candidate in [
    'parity/relationships/cases.json',
    '../parity/relationships/cases.json',
  ]) {
    final f = File(candidate);
    if (f.existsSync()) return f;
  }
  throw StateError('parity/relationships/cases.json not found from ${Directory.current.path}');
}

void main() {
  final fixture = jsonDecode(_fixtureFile().readAsStringSync()) as Map<String, dynamic>;
  final birthdayWithinDays = fixture['birthday_within_days'] as int;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  for (final c in cases) {
    if (c['reserved'] == true) continue; // Slice 7 fills this in later.
    final name = c['name'] as String;

    test('parity: $name', () {
      final now = DateTime.parse(c['now'] as String).toUtc();
      final peopleJson = (c['people'] as List).cast<Map<String, dynamic>>();
      final interactionsJson = (c['interactions'] as List).cast<Map<String, dynamic>>();

      // Last contact per person: the most recent interaction timestamp, same
      // rule `trackedPeopleFrom` applies ("only the most recent one matters").
      final lastContactByName = <String, DateTime>{};
      for (final i in interactionsJson) {
        final person = i['person'] as String;
        final at = DateTime.parse(i['at'] as String).toUtc();
        final known = lastContactByName[person];
        if (known == null || at.isAfter(known)) lastContactByName[person] = at;
      }

      final people = [
        for (final p in peopleJson)
          TrackedPerson(
            name: p['name'] as String,
            knownSince: DateTime.parse(p['known_since'] as String).toUtc(),
            contactEveryDays: p['contact_every_days'] as int?,
            lastContact: lastContactByName[p['name']],
            birthDate: p['birth_date'] == null ? null : DateTime.parse(p['birth_date'] as String),
          ),
      ];

      final due = contactsDue(people, now: now);
      final expectedDue = (c['expected']['due'] as List).cast<Map<String, dynamic>>();
      expect(due.map((d) => d.person.name).toList(), expectedDue.map((e) => e['name']).toList());
      expect(due.map((d) => d.daysSince).toList(), expectedDue.map((e) => e['days_since']).toList());

      final birthdays = upcomingBirthdays(
        [
          for (final p in people)
            if (p.birthDate != null) PersonBirthday(name: p.name, birthDate: p.birthDate!),
        ],
        today: now,
        withinDays: birthdayWithinDays,
      );
      final expectedBirthdays = (c['expected']['birthdays'] as List).cast<Map<String, dynamic>>();
      expect(birthdays.map((b) => b.person.name).toList(), expectedBirthdays.map((e) => e['name']).toList());
      expect(
        birthdays.map((b) => b.on).toList(),
        expectedBirthdays.map((e) => DateTime.parse(e['on'] as String)).toList(),
      );
      expect(birthdays.map((b) => b.turning).toList(), expectedBirthdays.map((e) => e['turning']).toList());
    });
  }
}
