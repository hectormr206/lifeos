// Patterns ACROSS domains — the thing LifeOS is ultimately for.
//
// The stated goal: "si le pregunto cómo ve mi salud, pueda tener relación de
// todas mis enfermedades... y no sólo eso, sino cómo estaban las finanzas, las
// relaciones, si hice ejercicio o lo dejé de hacer en tales fechas, y con todo
// este contexto pueda analizarlo... al final todo es estadística".
//
// It IS statistics, and that is exactly why this file is so cautious. With a
// handful of points, any two series look related. Told "tu presión sube cuando
// no haces ejercicio" on six observations, a person changes what they do about
// their own body — so the bar is not "is this interesting", it is "would this
// still be true with more data".
//
// THREE RULES, each one a test below:
//   1. It describes, never explains. "Coincide con" — never "por eso", never
//      "porque". Correlation stated as cause is the failure mode that hurts
//      someone, and no amount of data here would justify it.
//   2. It stays quiet until there is enough to say. Below the threshold there
//      is no observation at all, not a hedged one.
//   3. It never advises. No "deberías", no "toma", no "consulta" — that is a
//      doctor's sentence and this is a phone.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/daily_digest/domain/cross_domain_patterns.dart';
import 'package:lifeos/features/daily_digest/domain/digest_insights.dart';

void main() {
  final today = DateTime(2026, 8, 19);

  DigestDay day(int back, Map<String, int> counts) => DigestDay(
        date: today.subtract(Duration(days: back)),
        countsByDomain: counts,
      );

  group('it stays quiet without enough evidence', () {
    test('a few days say nothing', () {
      final found = crossDomainPatterns([
        day(0, {'exercise': 1, 'health': 1}),
        day(1, {'health': 1}),
      ], today: today);

      expect(found, isEmpty);
    });

    test('a domain logged only a couple of times is not a pattern', () {
      final found = crossDomainPatterns([
        for (var i = 0; i < 30; i++)
          day(i, i < 2 ? {'exercise': 1, 'health': 1} : {'health': 1}),
      ], today: today);

      expect(found.where((o) => o.contains('ejercicio')), isEmpty);
    });

    test('an empty history says nothing at all', () {
      expect(crossDomainPatterns(const [], today: today), isEmpty);
    });
  });

  group('what it will say, when there IS enough', () {
    /// Thirty days where exercise and health genuinely travel together.
    List<DigestDay> together() => [
          for (var i = 0; i < 30; i++)
            if (i.isEven)
              day(i, {'exercise': 1, 'health': 2})
            else
              day(i, {'finance': 1}),
        ];

    test('it names both domains in the user\'s language', () {
      final found = crossDomainPatterns(together(), today: today);

      expect(found.join(' ').toLowerCase(), contains('ejercicio'));
      expect(found.join(' ').toLowerCase(), contains('salud'));
    });

    test('it says they COINCIDE, never that one causes the other', () {
      final text = crossDomainPatterns(together(), today: today).join(' ');

      expect(text.toLowerCase(), contains('coincide'));
      for (final causal in ['porque', 'por eso', 'causa', 'provoca', 'debido a']) {
        expect(text.toLowerCase(), isNot(contains(causal)),
            reason: 'a coincidence was stated as a cause');
      }
    });

    test('it never advises', () {
      final text = crossDomainPatterns(together(), today: today).join(' ');

      for (final advice in ['deberías', 'te recomiendo', 'consulta', 'toma ',
        'evita', 'intenta']) {
        expect(text.toLowerCase(), isNot(contains(advice)));
      }
    });

    test('it says how many days it looked at, so the claim can be judged', () {
      // A statement about someone's life without its sample size invites more
      // trust than it earned.
      final text = crossDomainPatterns(together(), today: today).join(' ');

      expect(text, contains('30'));
    });
  });

  group('domains that have nothing to do with each other stay unpaired', () {
    test('two domains that never overlap produce nothing', () {
      final found = crossDomainPatterns([
        for (var i = 0; i < 30; i++)
          if (i < 15) day(i, {'exercise': 1}) else day(i, {'finance': 1}),
      ], today: today);

      expect(found.where((o) =>
          o.contains('ejercicio') && o.contains('finanzas')), isEmpty);
    });

    test('a domain is never paired with itself', () {
      final found = crossDomainPatterns([
        for (var i = 0; i < 30; i++) day(i, {'health': 2}),
      ], today: today);

      for (final observation in found) {
        expect('Salud'.allMatches(observation).length, lessThan(2));
      }
    });
  });

  group('the report is bounded', () {
    test('at most a couple of observations, so it stays readable', () {
      final found = crossDomainPatterns([
        for (var i = 0; i < 60; i++)
          day(i, i.isEven
              ? {'health': 1, 'exercise': 1, 'finance': 1, 'learning': 1}
              : {'relationships': 1, 'spirituality': 1}),
      ], today: today);

      expect(found.length, lessThanOrEqualTo(kMaxCrossDomainObservations));
    });
  });
}
