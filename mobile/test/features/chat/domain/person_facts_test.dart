// Telling Axi about a person, in the way people actually say it.
//
// Asked for: "si conocemos a una nueva persona... pudiéramos hablarle a Axi
// sobre él y que fuera guardando toda esta información, por ejemplo de cuántos
// hijos tiene, cuántos años tiene cada uno, si tiene esposa, sus papás, etc...
// para que si algún día tenemos una reunión nuevamente con él tengamos todo lo
// que conocemos de él y podamos hacerle plática".
//
// The value is entirely in the DETAIL surviving. "Juan tiene dos hijos" is
// worth nothing at the next dinner; "Mateo, de 8, juega futbol" is the thing
// that makes someone feel remembered — which is the whole point of the
// feature.
//
// So this reads the shape of the sentence in Dart rather than hoping a ~2B
// model returns clean JSON. It extracts only what was SAID: no inferred ages,
// no guessed genders, no invented relationships. What it cannot parse it
// leaves alone for the ordinary capture path.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/person_facts.dart';

void main() {
  group('family structure', () {
    test('a count of children', () {
      final facts = personFactsIn('Juan tiene dos hijos', subject: 'Juan');

      expect(facts, contains(PersonFact(subject: 'Juan', kind: 'hijos', value: '2')));
    });

    test('a numeral is read too', () {
      expect(personFactsIn('Juan tiene 3 hijos', subject: 'Juan'),
          contains(PersonFact(subject: 'Juan', kind: 'hijos', value: '3')));
    });

    test('children by NAME and age, which is the part that matters', () {
      final facts =
          personFactsIn('su hijo Mateo tiene 8 años', subject: 'Juan');

      expect(
        facts,
        contains(PersonFact(subject: 'Juan', kind: 'hijo', value: 'Mateo', detail: '8')),
      );
    });

    test('a spouse by name', () {
      final facts = personFactsIn('su esposa se llama Marta', subject: 'Juan');

      expect(facts,
          contains(PersonFact(subject: 'Juan', kind: 'esposa', value: 'Marta')));
    });

    test('parents', () {
      final facts = personFactsIn('su papá se llama Ramiro', subject: 'Juan');

      expect(facts,
          contains(PersonFact(subject: 'Juan', kind: 'papá', value: 'Ramiro')));
    });
  });

  group('the things that make conversation', () {
    test('where they work', () {
      expect(
        personFactsIn('trabaja en Bimbo', subject: 'Juan'),
        contains(PersonFact(subject: 'Juan', kind: 'trabajo', value: 'Bimbo')),
      );
    });

    test('what they like', () {
      expect(
        personFactsIn('le gusta el futbol', subject: 'Juan'),
        contains(PersonFact(subject: 'Juan', kind: 'gusto', value: 'el futbol')),
      );
    });

    test('where they live', () {
      expect(
        personFactsIn('vive en Puebla', subject: 'Juan'),
        contains(PersonFact(subject: 'Juan', kind: 'vive en', value: 'Puebla')),
      );
    });
  });

  group('what it refuses to do', () {
    test('with no subject it extracts nothing', () {
      // The rule that keeps facts off the wrong person: no owner, no fact.
      expect(personFactsIn('tiene dos hijos', subject: null), isEmpty);
    });

    test('a question is not a fact', () {
      expect(personFactsIn('¿cuántos hijos tiene?', subject: 'Juan'), isEmpty);
    });

    test('it does not invent an age it was not given', () {
      final facts = personFactsIn('su hijo se llama Mateo', subject: 'Juan');

      expect(facts,
          contains(PersonFact(subject: 'Juan', kind: 'hijo', value: 'Mateo')));
      expect(facts.first.detail, isNull);
    });

    test('an unparseable sentence yields nothing rather than a guess', () {
      expect(personFactsIn('ayer estuvo raro todo', subject: 'Juan'), isEmpty);
    });
  });

  group('rendering it back for a conversation', () {
    test('the facts read as sentences about that person', () {
      final lines = describePersonFacts([
        const PersonFact(subject: 'Juan', kind: 'esposa', value: 'Marta'),
        const PersonFact(subject: 'Juan', kind: 'hijo', value: 'Mateo', detail: '8'),
        const PersonFact(subject: 'Juan', kind: 'trabajo', value: 'Bimbo'),
      ]);

      expect(lines.join(' '), contains('Marta'));
      expect(lines.join(' '), contains('Mateo'));
      expect(lines.join(' '), contains('8'));
      expect(lines.join(' '), contains('Bimbo'));
    });

    test('nothing known reads as nothing, not as an empty heading', () {
      expect(describePersonFacts(const []), isEmpty);
    });
  });
}
