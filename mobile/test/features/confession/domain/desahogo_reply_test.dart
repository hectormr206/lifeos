// Nobody leaves the Desahogo worse than they arrived.
//
// Asked for: "si al final no lo va a procesar, entonces que el texto que se le
// dé sea neutral, pero que siempre, sin importar lo que le haya confesado, el
// texto sea satisfactorio para el usuario".
//
// That is the hardest requirement in the app and the most important one here.
// Someone has just said the thing they do not say out loud. If the model is
// missing, the phone is cold, or the text is too long, the app must still
// close the moment properly — "no pude responderte" after a confession is a
// door shutting in someone's face.
//
// So the reply is never allowed to be an error message. There is always a
// human close, written in advance, that works with no model at all.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/confession/domain/confession.dart';
import 'package:lifeos/features/confession/domain/confession_prompt.dart';

void main() {
  group('the reply when the model cannot answer', () {
    final reply = desahogoFallbackReply(languageCode: 'es');

    test('it acknowledges what the person did', () {
      // Saying it out loud IS the thing that helped. The close names that,
      // rather than apologising for the software.
      expect(reply.toLowerCase(), anyOf(contains('dijiste'), contains('decir')));
    });

    test('it never reads as an error', () {
      for (final excuse in ['no pude', 'error', 'falló', 'intenta de nuevo',
        'no disponible']) {
        expect(reply.toLowerCase(), isNot(contains(excuse)),
            reason: 'a confession answered with an error message');
      }
    });

    test('it does not pretend to have understood something specific', () {
      // Inventing a reflection it never read would be worse than saying
      // nothing: the person can tell, and then the whole space is a fake.
      for (final pretend in ['entiendo que', 'lo que me cuentas sobre',
        'por lo que dices']) {
        expect(reply.toLowerCase(), isNot(contains(pretend)));
      }
    });

    test('it never judges, forgives or advises', () {
      for (final forbidden in ['perdon', 'absuel', 'deberías', 'te recomiendo',
        'está mal', 'está bien lo que']) {
        expect(reply.toLowerCase(), isNot(contains(forbidden)));
      }
    });

    test('English has its own, not a translation artefact', () {
      final en = desahogoFallbackReply(languageCode: 'en');

      expect(en, isNotEmpty);
      expect(en, isNot(reply));
    });
  });

  group('very long confessions', () {
    // The local model holds 4096 tokens — roughly fifteen minutes of speaking.
    // Cutting someone off mid-sentence is the opposite of this feature, so the
    // recording is never stopped; what gets trimmed is what reaches the model.

    test('a short one is passed through untouched', () {
      const text = 'le grité a mi hija y me sentí terrible';

      expect(trimForDesahogo(text), text);
    });

    test('a very long one keeps the END, where people arrive at the point', () {
      // People open with context and close with the feeling. Keeping the
      // opening would answer the setup and miss what they came to say.
      final long = '${'contexto ' * 4000}y lo que de verdad me duele es esto';

      final trimmed = trimForDesahogo(long);
      expect(trimmed.length, lessThan(long.length));
      expect(trimmed, endsWith('y lo que de verdad me duele es esto'));
    });

    test('the trim stays inside the model\'s window', () {
      final long = 'palabra ' * 8000;

      expect(trimForDesahogo(long).length,
          lessThanOrEqualTo(kDesahogoMaxChars));
    });

    test('nothing is trimmed silently', () {
      // The user has to know the reply is about the last part, or they will
      // read the answer as a verdict on the whole thing.
      final long = 'palabra ' * 8000;

      expect(wasTrimmedForDesahogo(long), isTrue);
      expect(wasTrimmedForDesahogo('corto'), isFalse);
    });
  });
}
