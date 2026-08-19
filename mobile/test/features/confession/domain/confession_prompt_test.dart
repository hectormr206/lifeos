// Desahogo: a place to say something out loud and have it disappear.
//
// Asked for after the Catholic practice of confession, and deliberately only
// its ESSENCE: say the thing, be heard, be given something back, and have it
// gone. Not the sacrament, not a priest, no absolution granted in anyone's
// name — this app is a program on a phone and must never pretend otherwise.
//
// WHY IT HELPS, as far as anyone can honestly claim. Putting an experience
// into words is itself the active ingredient: the expressive-writing research
// begun by James Pennebaker in the 1980s found measurable benefits from
// writing about difficult experiences, and the effect did not depend on anyone
// reading it. What being heard adds is the removal of consequence — the
// specific relief of saying a thing where it cannot be used against you. And
// the ending matters: a ritual close is what separates "I dwelt on it" from "I
// set it down".
//
// So the design is: no storage anywhere, a reply that reflects rather than
// judges, and a visible destruction at the end. The destruction is not
// decoration — it is the part that makes the promise believable.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/confession/domain/confession_prompt.dart';

void main() {
  group('what the model is told to be', () {
    final prompt = buildConfessionPrompt(
      'le grité a mi hija y me sentí terrible',
      languageCode: 'es',
    );

    test('it hears the words the person actually said', () {
      expect(prompt, contains('le grité a mi hija y me sentí terrible'));
    });

    test('it is told NOT to judge', () {
      expect(prompt.toLowerCase(), contains('no juzgues'));
    });

    test('it is told not to give advice unless it is asked for', () {
      // Advice turns being heard into being fixed, and the whole point is the
      // first one.
      expect(prompt.toLowerCase(), contains('no des consejos'));
    });

    test('it is forbidden from granting absolution', () {
      // "Yo te absuelvo" from a program is a lie about what happened, and for
      // someone who takes the sacrament seriously it is worse than a lie.
      expect(prompt.toLowerCase(), contains('no absuelvas'));
      expect(prompt.toLowerCase(), contains('no eres un sacerdote'));
    });

    test('it is told to keep the reply short', () {
      // A paragraph of reflection reads as a lecture.
      expect(prompt.toLowerCase(), contains('breve'));
    });

    test('it is told nothing is being stored', () {
      // The model must not offer to "remember this for next time".
      expect(prompt.toLowerCase(), contains('no se guarda'));
    });
  });

  group('when it must stop reflecting and point somewhere real', () {
    test('a person in danger is given help, not a reflection', () {
      // The one case where "just listen" is the wrong answer. This does not
      // diagnose and does not refuse to listen — it adds a line naming that
      // help exists, because a program is not what someone in that state
      // needs and pretending otherwise could cost them.
      expect(
        confessionSafetyNote('ya no quiero vivir', languageCode: 'es'),
        isNotNull,
      );
      expect(
        confessionSafetyNote('quiero matarme', languageCode: 'es'),
        isNotNull,
      );
    });

    test('ordinary guilt is not treated as an emergency', () {
      // Over-triggering would turn every confession into a crisis screen, and
      // people stop using something that overreacts.
      expect(
        confessionSafetyNote('le mentí a mi jefe', languageCode: 'es'),
        isNull,
      );
      expect(
        confessionSafetyNote('me da miedo morir algún día', languageCode: 'es'),
        isNull,
      );
    });

    test('the English install gets the same protection', () {
      expect(
        confessionSafetyNote('i want to kill myself', languageCode: 'en'),
        isNotNull,
      );
    });
  });

  group('the closing', () {
    test('it names the ending without claiming to forgive', () {
      final closing = confessionClosing(languageCode: 'es');

      expect(closing, isNotEmpty);
      expect(closing.toLowerCase(), isNot(contains('te absuelvo')));
      expect(closing.toLowerCase(), isNot(contains('perdonad')));
    });

    test('it says the words are gone', () {
      // The promise, stated at the moment it is kept.
      expect(confessionClosing(languageCode: 'es').toLowerCase(),
          anyOf(contains('borr'), contains('desvanec'), contains('queda')));
    });

    test('English has its own closing, not a translation artefact', () {
      expect(confessionClosing(languageCode: 'en'), isNotEmpty);
      expect(confessionClosing(languageCode: 'en'),
          isNot(confessionClosing(languageCode: 'es')));
    });
  });
}
