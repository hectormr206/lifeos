// Axi opening with something, instead of waiting.
//
// Verified before proposing it: nothing in the app ever starts a conversation.
// Everything Axi knows is there because the user went and told it, which puts
// the whole burden on the busiest person in the room — and makes the chat a
// form rather than someone who knows you.
//
// This is NOT a notification. It is what the chat says when you open it, and
// it is built from what is already in the graph, so it can only ever mention
// something the user actually said.
//
// THE LINE IT MUST NOT CROSS: never invent a follow-up. "¿Cómo va la rodilla?"
// is only allowed if a knee was mentioned. An opener about something that
// never happened is the fastest way to make someone stop trusting the memory.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/opening_line.dart';

void main() {
  final now = DateTime(2026, 8, 19, 9);

  OpeningFact fact(String label, int daysAgo, {String? domain}) => OpeningFact(
        label: label,
        domain: domain,
        at: now.subtract(Duration(days: daysAgo)),
      );

  group('when it says nothing', () {
    test('an empty memory opens with nothing', () {
      // A brand-new user gets the ordinary screen, not a hollow "¿cómo estás?"
      // pretending to be personal.
      expect(openingLine(const [], now: now), isNull);
    });

    test('something from this morning is not worth asking about', () {
      // They just told you. Asking again reads as not having listened.
      expect(openingLine([fact('peso 82 kg', 0)], now: now), isNull);
    });

    test('something from months ago is left alone', () {
      // "¿Cómo va la rodilla?" about a knee from March is not attentive, it
      // is unsettling.
      expect(openingLine([fact('me duele la rodilla', 120)], now: now), isNull);
    });
  });

  group('what it opens with', () {
    test('it picks up something recent and open-ended', () {
      final line = openingLine(
        [fact('me duele la rodilla', 4, domain: 'health')],
        now: now,
      );

      expect(line, isNotNull);
      expect(line, contains('rodilla'));
    });

    test('it quotes the user\'s own words, never a paraphrase', () {
      // A paraphrase is where an invented detail sneaks in.
      final line = openingLine(
        [fact('empecé a correr en las mañanas', 3, domain: 'exercise')],
        now: now,
      );

      expect(line, contains('empecé a correr en las mañanas'));
    });

    test('it asks, and does not diagnose or advise', () {
      final line = openingLine(
        [fact('me duele la rodilla', 4, domain: 'health')],
        now: now,
      )!;

      expect(line, contains('?'));
      for (final forbidden in ['deberías', 'te recomiendo', 'seguro que',
        'probablemente']) {
        expect(line.toLowerCase(), isNot(contains(forbidden)));
      }
    });

    test('the most recent one wins when there are several', () {
      final line = openingLine([
        fact('me duele la rodilla', 6, domain: 'health'),
        fact('empecé un curso de inglés', 2, domain: 'learning'),
      ], now: now);

      expect(line, contains('inglés'));
    });
  });

  group('it never becomes noise', () {
    test('the same opener is not repeated twice in a row', () {
      // Opening the chat five times in one morning and being asked the same
      // question five times is how someone stops opening it.
      final facts = [fact('me duele la rodilla', 4, domain: 'health')];
      final first = openingLine(facts, now: now);

      expect(openingLine(facts, now: now, lastOpener: first), isNull);
    });
  });

  group('it does not greet you every time you open the chat', () {
    test('having spoken this morning silences it', () {
      // Five greetings in one morning is how someone stops opening the chat.
      final facts = [fact('me duele la rodilla', 4, domain: 'health')];

      expect(
        openingLine(facts,
            now: now, lastSpokeAt: now.subtract(const Duration(hours: 2))),
        isNull,
      );
    });

    test('a day later it speaks again', () {
      final facts = [fact('me duele la rodilla', 4, domain: 'health')];

      expect(
        openingLine(facts,
            now: now, lastSpokeAt: now.subtract(const Duration(days: 2))),
        isNotNull,
      );
    });
  });
}

