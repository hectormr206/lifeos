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
import 'package:lifeos/features/memory/domain/birthdays.dart';
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


LocalDomainEntry _act(String what, {required String side, DateTime? when}) => LocalDomainEntry(
      uuid: 'a::$what',
      label: what,
      timestamp: when ?? DateTime(2026, 8, 1),
      type: 'couple_act',
      data: {'what': what, 'side': side},
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

  // THE COUPLE OBSERVATION. Chapman's actual insight is not "learn the five
  // languages" — it is that each person GIVES love in their own, and their
  // partner may not receive it in that one. Two people genuinely trying,
  // neither feeling loved. Software can notice that mismatch; it cannot fix it,
  // and it must not turn affection into a chore.
  //
  // Which is why most of these tests are about SILENCE.
  group('the couple observation', () {
    test('names the mismatch between what is given and what is valued', () {
      final r = relationshipReminders([
        _act('le lavé el coche', side: 'gave'),
        _act('le arreglé la puerta', side: 'gave'),
        _act('le hice el desayuno', side: 'gave'),
        _act('dijo que extraña que salgamos solos', side: 'valued'),
        _act('me pidió que platicáramos sin teléfonos', side: 'valued'),
        _act('le gustó nuestra caminata juntos', side: 'valued'),
      ], now: today);

      expect(r.loveLanguages, isNotNull);
      final text = r.loveLanguages!.describe();
      expect(text, contains('actos de servicio'));
      expect(text, contains('tiempo de calidad'));
    });

    test('reads as an observation, never as an instruction', () {
      final r = relationshipReminders([
        _act('le lavé el coche', side: 'gave'),
        _act('le arreglé la puerta', side: 'gave'),
        _act('le hice el desayuno', side: 'gave'),
        _act('extraña que salgamos solos', side: 'valued'),
        _act('quiere que platiquemos sin teléfonos', side: 'valued'),
        _act('le gustó la caminata juntos', side: 'valued'),
      ], now: today);

      final text = r.loveLanguages!.describe().toLowerCase();
      for (final imperative in ['deberías', 'tienes que', 'recuerda', 'haz ']) {
        expect(text, isNot(contains(imperative)));
      }
      for (final gamified in ['%', 'racha', 'puntos', 'meta']) {
        expect(text, isNot(contains(gamified)));
      }
    });

    test('says nothing on thin evidence', () {
      // Two data points are an anecdote, and announcing a pattern from an
      // anecdote is how software earns distrust on something this personal.
      final r = relationshipReminders([
        _act('le lavé el coche', side: 'gave'),
        _act('extraña que salgamos solos', side: 'valued'),
      ], now: today);

      expect(r.loveLanguages, isNull);
    });

    test('says nothing when only one side was recorded', () {
      final r = relationshipReminders([
        _act('le lavé el coche', side: 'gave'),
        _act('le arreglé la puerta', side: 'gave'),
        _act('le hice el desayuno', side: 'gave'),
        _act('le llené el tanque', side: 'gave'),
      ], now: today);

      expect(r.loveLanguages, isNull);
    });

    test('says nothing when both already speak the same language', () {
      final r = relationshipReminders([
        _act('le lavé el coche', side: 'gave'),
        _act('le arreglé la puerta', side: 'gave'),
        _act('le hice el desayuno', side: 'gave'),
        _act('dijo que le encanta cuando le arreglo cosas', side: 'valued'),
        _act('agradeció que le hiciera el desayuno', side: 'valued'),
        _act('dijo que le ayudó que lavara el coche', side: 'valued'),
      ], now: today);

      expect(r.loveLanguages, isNull);
    });

    test('an act it cannot read is skipped, never guessed', () {
      final r = relationshipReminders([
        _act('fuimos al súper', side: 'gave'),
        _act('pasó algo', side: 'valued'),
      ], now: today);

      expect(r.loveLanguages, isNull);
    });

    test('an act with no text is not an act', () {
      final r = relationshipReminders([
        LocalDomainEntry(
          uuid: 'x',
          label: '',
          timestamp: DateTime(2026, 8, 1),
          type: 'couple_act',
          data: const {'side': 'gave'},
        ),
      ], now: today);

      expect(r.loveLanguages, isNull);
      expect(r.isEmpty, isTrue);
    });

    test('couple acts do not become people, birthdays or nudges', () {
      // Different entry type, different meaning — a recorded act is not
      // someone to write to.
      final r = relationshipReminders([
        _act('le lavé el coche', side: 'gave'),
        _act('extraña que salgamos solos', side: 'valued'),
      ], now: today);

      expect(r.birthdays, isEmpty);
      expect(r.due, isEmpty);
    });
  });


  // NAMES CARRY SURNAMES, AND PEOPLE DO NOT REPEAT THEM.
  //
  // You record a friend the way a contact list wants it — "Juan Pérez García" —
  // and then record his daughter the way you would SAY it: "hija de Juan". The
  // exact-match link never fired, so the two silently stayed unconnected and
  // the whole point of families (a child's birthday as a reason to write to the
  // parent) quietly did nothing.
  group('names with surnames still link', () {
    test('a first name in the relation finds the person recorded in full', () {
      final r = relationshipReminders([
        _person('Juan Pérez García', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
        _person('Sofía', knownSince: DateTime(2020, 1, 1), relation: 'hija de Juan', birthDate: '2019-08-10'),
      ], now: today);

      expect(r.due.single.context, isNotNull);
      expect(r.due.single.message(), contains('Sofía'));
    });

    test('a full name in the relation finds the person recorded short', () {
      final r = relationshipReminders([
        _person('Juan', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
        _person('Sofía', knownSince: DateTime(2020, 1, 1),
            relation: 'hija de Juan Pérez García', birthDate: '2019-08-10'),
      ], now: today);

      expect(r.due.single.context, isNotNull);
    });

    test('the exact full name still matches', () {
      final r = relationshipReminders([
        _person('Juan Pérez García', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
        _person('Sofía', knownSince: DateTime(2020, 1, 1),
            relation: 'hija de Juan Pérez García', birthDate: '2019-08-10'),
      ], now: today);

      expect(r.due.single.context, isNotNull);
    });

    test('TWO Juanes → no link at all, rather than the wrong one', () {
      // Precision over reach. Guessing which Juan would put someone else's
      // daughter in your friend's picture, and the user would have no way to
      // tell it was wrong.
      final r = relationshipReminders([
        _person('Juan Pérez', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
        _person('Juan Ramírez', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
        _person('Sofía', knownSince: DateTime(2020, 1, 1), relation: 'hija de Juan', birthDate: '2019-08-10'),
      ], now: today);

      for (final due in r.due) {
        expect(due.context, isNull, reason: 'ambiguous "Juan" must not be resolved');
      }
    });

    test('a partial word is not a name match', () {
      // "Juana" is not "Juan".
      final r = relationshipReminders([
        _person('Juana', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
        _person('Sofía', knownSince: DateTime(2020, 1, 1), relation: 'hija de Juan', birthDate: '2019-08-10'),
      ], now: today);

      expect(r.due.single.context, isNull);
    });
  });

  group('every kind of relationship people actually write', () {
    for (final word in ['primo', 'prima', 'tío', 'tía', 'abuelo', 'abuela', 'hermano',
                        'sobrina', 'compañero', 'colega', 'cuñada', 'suegra']) {
      test('"$word de Juan" links to Juan', () {
        final r = relationshipReminders([
          _person('Juan', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
          _person('X', knownSince: DateTime(2020, 1, 1), relation: '$word de Juan', birthDate: '2019-08-10'),
        ], now: today);

        expect(r.due.single.context, isNotNull, reason: word);
      });
    }

    for (final standalone in ['amigo', 'amiga', 'vecina', 'colega del trabajo', 'compañera de la oficina']) {
      test('"$standalone" names nobody, so it links to nobody', () {
        final r = relationshipReminders([
          _person('Juan', knownSince: DateTime(2020, 1, 1), contactEveryDays: 30),
          _person('X', knownSince: DateTime(2020, 1, 1), relation: standalone, birthDate: '2019-08-10'),
        ], now: today);

        expect(r.due.single.context, isNull, reason: standalone);
      });
    }
  });


  // YOU DO NOT SAY EVERYTHING AT ONCE.
  //
  // You record "Oscar García, cumpleaños 10/07" today, and next week you
  // remember he is your brother-in-law and record that. Two entries, one human.
  //
  // The old behaviour took the NEWEST RECORD whole, so the second entry — which
  // carried a relation and no birth date — quietly erased the birthday. Nothing
  // failed, nothing warned: the date simply stopped existing, and the reminder
  // it fed stopped appearing. Measured before fixing: 0 birthdays survived.
  group('a person told in pieces keeps every piece', () {
    // list() hands back newest-first; the tests mirror that.
    LocalDomainEntry oscar(DateTime when, {String? relation, String? birth, int? cadence}) =>
        LocalDomainEntry(
          uuid: 'oscar-$when',
          label: 'Oscar García',
          timestamp: when,
          type: 'person',
          data: {
            'name': 'Oscar García',
            'relation': ?relation,
            'birth_date': ?birth,
            'contact_every_days': ?cadence,
          },
        );

    test('adding the relation later does not erase the birthday', () {
      final r = relationshipReminders([
        oscar(DateTime(2026, 8, 5), relation: 'mi cuñado'),
        oscar(DateTime(2026, 8, 4), birth: '2026-08-10'),
      ], now: today);

      expect(r.birthdays, hasLength(1));
      expect(r.birthdays.single.person.relation, 'mi cuñado');
    });

    test('adding the birthday later does not erase the relation', () {
      final r = relationshipReminders([
        oscar(DateTime(2026, 8, 5), birth: '2026-08-10'),
        oscar(DateTime(2026, 8, 4), relation: 'mi cuñado'),
      ], now: today);

      expect(r.birthdays.single.person.relation, 'mi cuñado');
      expect(r.birthdays.single.on, DateTime(2026, 8, 10));
    });

    test('a correction wins — the newest value of a field is the one meant', () {
      final r = relationshipReminders([
        oscar(DateTime(2026, 8, 5), relation: 'mi cuñado'),
        oscar(DateTime(2026, 8, 4), relation: 'mi primo', birth: '2026-08-10'),
      ], now: today);

      expect(r.birthdays.single.person.relation, 'mi cuñado');
      // ...and the field he did not correct survives untouched.
      expect(r.birthdays.single.on, DateTime(2026, 8, 10));
    });

    test('a cadence added later starts nudging, keeping the rest', () {
      final r = relationshipReminders([
        oscar(DateTime(2026, 8, 5), cadence: 30),
        oscar(DateTime(2020, 1, 1), relation: 'mi cuñado', birth: '2026-08-10'),
      ], now: today);

      expect(r.due, hasLength(1));
      expect(r.due.single.person.name, 'Oscar García');
      expect(r.birthdays, hasLength(1));
    });

    test('the person is still ONE person, not two', () {
      final r = relationshipReminders([
        oscar(DateTime(2026, 8, 5), relation: 'mi cuñado'),
        oscar(DateTime(2026, 8, 4), birth: '2026-08-10'),
      ], now: today);

      expect(r.birthdays, hasLength(1));
    });

    test('order of arrival does not change the result', () {
      List<UpcomingBirthday> run(List<LocalDomainEntry> e) =>
          relationshipReminders(e, now: today).birthdays;

      final a = oscar(DateTime(2026, 8, 5), relation: 'mi cuñado');
      final b = oscar(DateTime(2026, 8, 4), birth: '2026-08-10');

      expect(run([a, b]).single.describe(), run([b, a]).single.describe());
    });
  });

}
