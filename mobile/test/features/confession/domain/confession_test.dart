// The confession space: say it once, be heard, let it go.
//
// WHAT THIS IS. Asked for after the Catholic practice, and explicitly not the
// whole of it: "no quiero todo esto, pero sí quiero hacer la esencia de la
// confesión... la meta es que al final te sientas aliviado de confesarle a
// alguien lo que has hecho, pensado... y al final ya con una respuesta o
// frase y todo se borra, nada queda guardado en ningún lado".
//
// WHY IT WORKS, as far as anyone can say. Putting something into words is
// itself most of the relief: expressive writing about a difficult experience
// has been studied since the 1980s (Pennebaker's work is the best known) and
// the reliable finding is that ARTICULATION helps — turning a formless dread
// into sentences with a beginning and an end. Two more things matter here and
// come from the practice rather than the lab: being heard by someone who will
// not repeat it, and a clear ENDING. The ritual closes. You do not carry the
// paper home.
//
// So this is built on three properties, and each one is a test below:
//   1. Nothing is stored. Not the words, not a summary, not a count.
//   2. It never claims to forgive on anyone's behalf. It is not a priest, not
//      a sacrament, and saying otherwise to someone in a vulnerable moment
//      would be a real harm dressed as comfort.
//   3. It ends deliberately, and the ending is visible.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/confession/domain/confession.dart';

void main() {
  group('what the model is told', () {
    final prompt = confessionPreamble(languageCode: 'es');

    test('it carries NO memory of the user', () {
      // The ordinary chat prefixes every turn with a MEMORIA RELEVANTE block
      // recalled from the graph. Here that would be the opposite of the
      // point: a confession is not annotated with your health data, and a
      // model that can quote your life back at you is not a stranger.
      expect(prompt, isNot(contains('MEMORIA')));
      expect(prompt.toLowerCase(), isNot(contains('memoria relevante')));
    });

    test('it is told it cannot absolve anyone', () {
      // The one line that must never be crossed. Telling someone their sins
      // are forgiven, in a moment when they came looking for exactly that, is
      // a harm dressed as comfort — and it is a claim no software can make.
      expect(prompt.toLowerCase(), contains('no eres un sacerdote'));
      expect(prompt.toLowerCase(), contains('no absuelves'));
    });

    test('it is told not to judge', () {
      expect(prompt.toLowerCase(), contains('no juzgues'));
    });

    test('it is told to be brief', () {
      // A wall of text after someone finally said the hard thing reads as a
      // lecture. The practice ends with a few words, not an essay.
      expect(prompt.toLowerCase(), contains('breve'));
    });

    test('it is told to name the feeling rather than fix the problem', () {
      expect(prompt.toLowerCase(), contains('nombra'));
    });

    test('it points to real help when someone is in danger', () {
      // The one case where "just listen" is the wrong answer.
      expect(prompt.toLowerCase(), contains('ayuda'));
    });

    test('an English install gets the same guarantees', () {
      final en = confessionPreamble(languageCode: 'en');

      expect(en.toLowerCase(), contains('you are not a priest'));
      expect(en.toLowerCase(), contains('do not judge'));
      expect(en, isNot(contains('MEMORIA')));
    });
  });

  group('nothing survives the session', () {
    test('a session holds the words only while it is open', () {
      final session = ConfessionSession()..write('lo que hice el martes');

      expect(session.text, contains('martes'));

      session.release();

      expect(session.text, isEmpty,
          reason: 'the words outlived the moment they were said in');
    });

    test('releasing twice is harmless', () {
      final session = ConfessionSession()..write('algo');
      session.release();

      expect(session.release, returnsNormally);
    });

    test('a released session keeps no count, no length, no trace', () {
      // Not even metadata: "you confessed 4 times this month" is a record of
      // the thing that was promised not to be recorded.
      final session = ConfessionSession()..write('una frase larga y concreta');
      session.release();

      expect(session.toString(), isNot(contains('frase')));
      expect(session.hasContent, isFalse);
    });
  });

  group('the closing', () {
    test('it acknowledges the ending without granting absolution', () {
      final closing = confessionClosing(languageCode: 'es');

      expect(closing, isNotEmpty);
      for (final forbidden in ['perdonad', 'absuel', 'pecados te']) {
        expect(closing.toLowerCase(), isNot(contains(forbidden)),
            reason: 'the closing must not pretend to forgive');
      }
    });

    test('it says the words are gone, because they are', () {
      expect(confessionClosing(languageCode: 'es').toLowerCase(),
          anyOf(contains('se fue'), contains('aquí queda'), contains('borr')));
    });

    test('English closes too', () {
      expect(confessionClosing(languageCode: 'en'), isNotEmpty);
    });
  });
}
