// Characterization lock (relationships-robustness, Slice 1).
//
// Locks TODAY's folding and relation-target-parse behaviour before Slice 2+
// changes anything about person identity. These assertions MUST pass against
// the current, unmodified code — this is a lock, not a RED-then-GREEN pair.
// Slice 2's collision guard revisits whether folding two different accents
// into one key is still correct; this file only records what happens today.
//
// `_key()` and `_relationTarget()` in relationship_reminders.dart are private,
// so the lock goes through the public `relationshipReminders`/
// `trackedPeopleFrom` surface — the same one the app itself calls.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/domain/local_domain_entry.dart';
import 'package:lifeos/features/memory/domain/relationship_reminders.dart';

LocalDomainEntry _person(
  String name, {
  required DateTime knownSince,
  String? relation,
  int? contactEveryDays,
}) =>
    LocalDomainEntry(
      uuid: 'p::$name::$knownSince',
      label: name,
      timestamp: knownSince,
      type: 'person',
      data: {
        'name': name,
        'relation': ?relation,
        'contact_every_days': ?contactEveryDays,
      },
    );

LocalDomainEntry _interaction(String person, DateTime when) => LocalDomainEntry(
      uuid: 'i::$person::${when.toIso8601String()}',
      label: 'Interacción con $person',
      timestamp: when,
      type: 'interaction',
      data: {'person': person},
    );

void main() {
  final today = DateTime(2026, 8, 4);

  group('folding characterization (today\'s accent/case fold rule)', () {
    test('"María" and "maria" resolve to the same tracked person', () {
      final r = relationshipReminders([
        _person('María', knownSince: DateTime(2026, 1, 1), contactEveryDays: 30),
        _interaction('maria', DateTime(2026, 8, 2)),
      ], now: today);

      // Same key today → the interaction resets María's clock, so she is not
      // due. This is the behaviour Slice 2's collision guard will revisit,
      // never silently — it is characterized here first.
      expect(r.due, isEmpty, reason: '"maria" folds to the same key as "María"');
    });

    test('"José" and "jose" resolve to the same tracked person', () {
      final r = relationshipReminders([
        _person('José', knownSince: DateTime(2026, 1, 1), contactEveryDays: 30),
        _interaction('JOSE', DateTime(2026, 8, 2)),
      ], now: today);

      expect(r.due, isEmpty, reason: '"JOSE" folds to the same key as "José"');
    });

    test('a name recorded twice under different casing still appears once', () {
      final people = trackedPeopleFrom([
        _person('Ana', knownSince: DateTime(2026, 2, 1)),
        _person('ANA', knownSince: DateTime(2026, 1, 1)),
      ]);
      expect(people, hasLength(1), reason: 'today\'s fold merges same-key entries into one person');
    });
  });

  group('relation-target parse characterization (`\\bde\\s+(.+)\$`)', () {
    test('"hija de Juan" parses "Juan" as the target', () {
      final people = trackedPeopleFrom([
        _person('Juan', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
        _person('Sofía', knownSince: DateTime(2020, 1, 1), relation: 'hija de Juan'),
      ]);
      final juan = people.firstWhere((p) => p.name == 'Juan');
      expect(juan.family.map((f) => f.name), contains('Sofía'));
    });

    test('a relation with no "de" clause names nobody', () {
      final people = trackedPeopleFrom([
        _person('Juan', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
        _person('Ana', knownSince: DateTime(2020, 1, 1), relation: 'vecina'),
      ]);
      final juan = people.firstWhere((p) => p.name == 'Juan');
      expect(juan.family, isEmpty);
    });

    test('the parse takes everything AFTER the last "de", case-insensitively', () {
      final people = trackedPeopleFrom([
        _person('Juan', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
        _person('X', knownSince: DateTime(2020, 1, 1), relation: 'AMIGO DE JUAN'),
      ]);
      final juan = people.firstWhere((p) => p.name == 'Juan');
      expect(juan.family.map((f) => f.name), contains('X'));
    });
  });
}
