// What to do INSTEAD of telling someone what to take.
//
// He asked for notifications "de qué hacer o qué tomar". The second half is a
// medical instruction and this app will not give one — not because of caution
// for its own sake, but because nothing here can support it: a phone counting
// entries has no idea what someone should take, and a confident wrong answer
// about that is the kind of harm you cannot undo with an update.
//
// The better version of the same wish is this: LifeOS knows what YOU used to
// do and stopped doing, and can offer to help you pick it back up. That is
// actionable, it comes from the user's own history, and it never claims to
// know anything about their body.
//
//   "Llevabas cuatro semanas anotando tu presión y llevas 9 días sin hacerlo.
//    ¿Te lo recuerdo mañana a las 9?"
//
// The difference is the whole point: this offers to help with something the
// person already decided to do, instead of deciding for them.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/daily_digest/domain/digest_insights.dart';
import 'package:lifeos/features/daily_digest/domain/digest_nudges.dart';

void main() {
  final today = DateTime(2026, 8, 19);

  DigestDay day(int back, Map<String, int> counts) => DigestDay(
        date: today.subtract(Duration(days: back)),
        countsByDomain: counts,
      );

  group('offering to help pick a habit back up', () {
    /// Logged health daily for a month, then stopped nine days ago.
    List<DigestDay> lapsed() => [
          for (var i = 9; i < 40; i++) day(i, {'health': 1}),
          for (var i = 0; i < 9; i++) day(i, {'exercise': 1}),
        ];

    test('it offers a reminder for what was dropped', () {
      final offers = digestNudges(lapsed(), today: today);

      expect(offers, isNotEmpty);
      expect(offers.first.domain, 'health');
    });

    test('the offer is a QUESTION, not an instruction', () {
      final offer = digestNudges(lapsed(), today: today).first;

      expect(offer.message, contains('?'));
      for (final order in ['debes', 'deberías', 'tienes que', 'toma ',
        'consulta']) {
        expect(offer.message.toLowerCase(), isNot(contains(order)));
      }
    });

    test('it says how long the habit ran, so the offer is grounded', () {
      final offer = digestNudges(lapsed(), today: today).first;

      expect(offer.message, contains('9'));
    });

    test('it never names a substance, a dose or a symptom', () {
      // The line this exists to hold.
      final offer = digestNudges(lapsed(), today: today).first;

      for (final medical in ['mg', 'pastilla', 'medicamento', 'dosis',
        'presión alta', 'diabet']) {
        expect(offer.message.toLowerCase(), isNot(contains(medical)));
      }
    });
  });

  group('when it says nothing', () {
    test('a habit still going gets no offer', () {
      final offers = digestNudges([
        for (var i = 0; i < 40; i++) day(i, {'health': 1}),
      ], today: today);

      expect(offers, isEmpty);
    });

    test('something never done regularly is not a lapse', () {
      // Nagging about a domain someone tried twice is how an app gets muted.
      final offers = digestNudges([
        for (var i = 0; i < 40; i++)
          if (i == 30 || i == 31) day(i, {'finance': 1}) else day(i, {'exercise': 1}),
      ], today: today);

      expect(offers.where((o) => o.domain == 'finance'), isEmpty);
    });

    test('a two-day pause is not a lapse either', () {
      final offers = digestNudges([
        for (var i = 2; i < 40; i++) day(i, {'health': 1}),
        day(0, {'exercise': 1}),
      ], today: today);

      expect(offers, isEmpty);
    });

    test('a thin history says nothing at all', () {
      expect(digestNudges(const [], today: today), isEmpty);
    });
  });

  group('it stays quiet enough to be listened to', () {
    test('at most one offer at a time', () {
      // Three "want a reminder?" questions in one summary is a form to fill
      // in, and people close forms.
      final offers = digestNudges([
        for (var i = 12; i < 50; i++)
          day(i, {'health': 1, 'exercise': 1, 'finance': 1}),
        for (var i = 0; i < 12; i++) day(i, {'learning': 1}),
      ], today: today);

      expect(offers.length, lessThanOrEqualTo(1));
    });
  });
}
