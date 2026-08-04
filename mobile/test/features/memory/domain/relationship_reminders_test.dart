// Proves the bridge between what the user WROTE DOWN and the relationship
// logic that had, until now, nothing to read.
//
// The birthday and contact-nudge rules were written and tested as pure
// functions, and then nothing called them: the app could store a person and do
// nothing with them afterwards. These tests are about the wiring — that a
// person typed into the Relaciones form comes back as a reason to reach out.
//
// The idea worth protecting: the reminder must carry a REASON, not a
// countdown. "Hace 45 días que no hablas con Juan" is administrative guilt.
// "Sofía (hija de Juan) cumple 7 el 10" is something to write about.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/domain/local_domain_entry.dart';
import 'package:lifeos/features/memory/domain/relationship_reminders.dart';

LocalDomainEntry _person(
  String name, {
  required DateTime knownSince,
  String? relation,
  String? birthDate,
  int? contactEveryDays,
}) =>
    LocalDomainEntry(
      uuid: 'p::$name',
      label: name,
      timestamp: knownSince,
      type: 'person',
      data: {
        'name': name,
        'relation': ?relation,
        'birth_date': ?birthDate,
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

  group('a person the user typed in becomes someone to remember', () {
    test('their birthday surfaces with the age they are turning', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2026, 1, 1), birthDate: '1988-08-10'),
      ], now: today);

      expect(r.birthdays, hasLength(1));
      expect(r.birthdays.single.person.name, 'Juan');
      expect(r.birthdays.single.turning, 38);
      expect(r.birthdays.single.daysAway, 6);
    });

    test('a person with no birth date is simply not in the birthday list', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2026, 1, 1)),
      ], now: today);

      expect(r.birthdays, isEmpty);
    });

    test('a date-only birth date is read as the day the user picked', () {
      // The Persona form stores YYYY-MM-DD precisely so a timezone conversion
      // can never move it. Reading it back must not undo that.
      final r = relationshipReminders([
        _person('Sofía', knownSince: DateTime(2026, 1, 1), birthDate: '2019-08-10'),
      ], now: today);

      expect(r.birthdays.single.on, DateTime(2026, 8, 10));
      expect(r.birthdays.single.turning, 7);
    });
  });

  group('the cadence the user chose', () {
    test('someone never contacted becomes due once their cadence elapses', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2026, 6, 1), contactEveryDays: 30),
      ], now: today);

      expect(r.due, hasLength(1));
      expect(r.due.single.person.name, 'Juan');
    });

    test('an interaction resets the clock — no schedule to reschedule', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2026, 6, 1), contactEveryDays: 30),
        _interaction('Juan', DateTime(2026, 8, 1)),
      ], now: today);

      expect(r.due, isEmpty, reason: 'spoke 3 days ago, cadence is 30');
    });

    test('the most recent interaction wins, whatever order they arrive in', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2026, 1, 1), contactEveryDays: 30),
        _interaction('Juan', DateTime(2026, 8, 2)),
        _interaction('Juan', DateTime(2026, 3, 1)),
      ], now: today);

      expect(r.due, isEmpty);
    });

    test('a person with no cadence is never nudged about', () {
      // Not everyone is a task. Leaving it blank must mean silence.
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2020, 1, 1)),
      ], now: today);

      expect(r.due, isEmpty);
    });

    test('matching a person to their interactions ignores case and accents', () {
      final r = relationshipReminders([
        _person('Sofía', knownSince: DateTime(2026, 1, 1), contactEveryDays: 30),
        _interaction('sofia', DateTime(2026, 8, 2)),
      ], now: today);

      expect(r.due, isEmpty, reason: '"sofia" is the same human as "Sofía"');
    });
  });

  group('family is derived from how people actually write it', () {
    test('"hija de Juan" links Sofía into Juan\'s picture', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2026, 1, 1), contactEveryDays: 30),
        _person('Sofía',
            knownSince: DateTime(2026, 1, 1), relation: 'hija de Juan', birthDate: '2019-08-10'),
      ], now: today);

      // Juan is overdue, and the reason offered is his daughter's birthday —
      // something to write ABOUT, not a count of silent days.
      expect(r.due.single.person.name, 'Juan');
      expect(r.due.single.context, isNotNull);
      expect(r.due.single.message(), contains('Sofía'));
      expect(r.due.single.message(), contains('7'));
    });

    test('the nudge never shows the day count', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2026, 1, 1), contactEveryDays: 30),
        _person('Sofía',
            knownSince: DateTime(2026, 1, 1), relation: 'hija de Juan', birthDate: '2019-08-10'),
      ], now: today);

      final message = r.due.single.message();
      expect(message, isNot(contains('215')));
      expect(message.toLowerCase(), isNot(contains('días sin')));
    });

    test('a relation naming nobody links to nobody', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2026, 1, 1), contactEveryDays: 30),
        _person('Ana', knownSince: DateTime(2026, 1, 1), relation: 'vecina', birthDate: '1990-08-10'),
      ], now: today);

      // Ana's birthday is still hers, but it is not a reason to write to Juan.
      expect(r.birthdays.map((b) => b.person.name), contains('Ana'));
      expect(r.due.single.context, isNull);
    });

    test('an explicit cadence on a family member is still honoured', () {
      // Being someone's daughter does not cancel an instruction the user typed.
      // If they asked to be reminded about Sofía, they get reminded about
      // Sofía — the family link adds a reason to write to Juan, it does not
      // take Sofía off the list. Deciding otherwise would be the app
      // overruling a choice the user made in a form.
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
        _person('Sofía',
            knownSince: DateTime(2020, 1, 1),
            relation: 'hija de Juan',
            contactEveryDays: 30),
      ], now: today);

      expect(r.due.map((d) => d.person.name), containsAll(['Juan', 'Sofía']));
    });

    test('a family member with NO cadence is only surfaced through their person', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
        _person('Sofía',
            knownSince: DateTime(2020, 1, 1),
            relation: 'hija de Juan',
            birthDate: '2019-08-10'),
      ], now: today);

      // Silence about Sofía herself; her birthday is Juan's reason to write.
      expect(r.due.map((d) => d.person.name), ['Juan']);
      expect(r.due.single.message(), contains('Sofía'));
    });
  });

  group('what it refuses to do', () {
    test('no entries → nothing to say', () {
      final r = relationshipReminders(const [], now: today);

      expect(r.isEmpty, isTrue);
    });

    test('a person recorded twice appears once', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2026, 2, 1), birthDate: '1988-08-10'),
        _person('Juan', knownSince: DateTime(2026, 1, 1), birthDate: '1988-08-10'),
      ], now: today);

      expect(r.birthdays, hasLength(1));
    });

    test('an entry with no name is skipped, never rendered blank', () {
      final r = relationshipReminders([
        LocalDomainEntry(
          uuid: 'x',
          label: '',
          timestamp: DateTime(2026, 1, 1),
          type: 'person',
          data: const {'birth_date': '1988-08-10'},
        ),
      ], now: today);

      expect(r.isEmpty, isTrue);
    });

    test('a nonsense cadence is treated as no cadence', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2020, 1, 1), contactEveryDays: 0),
      ], now: today);

      expect(r.due, isEmpty);
    });

    test('an unparseable birth date is ignored, not guessed', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2026, 1, 1), birthDate: 'cuando era joven'),
      ], now: today);

      expect(r.birthdays, isEmpty);
    });
  });
}
