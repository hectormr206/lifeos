// A person's circle, and the dates that matter besides their birthday.
//
// Asked for: "poder tener las relaciones personales como familia, amigos,
// conocidos, relaciones laborales, etc... llevar ese registro como cumpleaños
// y que tuviéramos esos recordatorios, o fechas especiales".
//
// Two gaps, both concrete:
//   * The circle was free text ("ej. hija de Juan"), so "¿quiénes son mis
//     compañeros de trabajo?" had no answer and nothing could be grouped.
//   * The only date was a birthday. An anniversary, the day you met someone,
//     a saint's day — none of them existed, and those are exactly the dates
//     people are mortified to forget.
//
// The circle is a PICK-LIST for the same reason the briefing sections are:
// typed, it becomes "trabajo", "Trabajo" and "laboral" for one idea, and then
// nothing groups.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/domains/domain/local_entry_config.dart';

void main() {
  group('the person entry', () {
    final person = localEntryTypeFor('relationships', 'person')!;
    final fields = {for (final f in person.fields) f.key: f};

    test('it asks which circle they belong to', () {
      expect(fields.containsKey('circle'), isTrue);
    });

    test('the circle is chosen from a list, never typed', () {
      expect(fields['circle']!.enumOptions, isNotNull);
      expect(fields['circle']!.enumOptions, isNotEmpty);
    });

    test('the circles are the ones a person actually has', () {
      final labels = fields['circle']!.enumLabels!.values.join(' ').toLowerCase();

      for (final expected in ['familia', 'amig', 'conocid', 'trabajo']) {
        expect(labels, contains(expected));
      }
    });

    test('the circle is optional: a name alone is still a person', () {
      // Forcing a category on someone you just met turns "guardar a alguien"
      // into a form, and the whole point is that it takes one sentence.
      expect(fields['circle']!.required, isFalse);
    });

    test('the birthday is still there', () {
      expect(fields.containsKey('birth_date'), isTrue);
    });
  });

  group('special dates', () {
    final special = localEntryTypeFor('relationships', 'special_date');

    test('there is a way to record one at all', () {
      expect(special, isNotNull,
          reason: 'anniversaries and the day you met had nowhere to live');
    });

    test('it needs a person, a date and what it IS', () {
      final fields = {for (final f in special!.fields) f.key: f};

      expect(fields['person']!.required, isTrue);
      // Keyed `ts` like every other entry: that is what the registry, the day
      // grouping and the digest all read.
      expect(fields['ts']!.required, isTrue);
      expect(fields['what']!.required, isTrue);
    });

    test('the date is a day, not a timestamp', () {
      // An anniversary has no 14:32 about it, and asking for one is how a
      // simple entry becomes a chore.
      final fields = {for (final f in special!.fields) f.key: f};

      expect(fields['ts']!.dateOnly, isTrue);
    });
  });
}
