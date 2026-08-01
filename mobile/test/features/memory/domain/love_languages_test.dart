// Proves the couple observation, and — more importantly — proves what it
// REFUSES to do.
//
// The naive reading of Chapman is: quiz for the five languages, store the
// partner's, remind the user to "perform an act of service". That turns
// affection into an overdue chore and gets muted within a week. It is not
// built here, and these tests hold that line.
//
// The book's actual insight: each person gives love in their own language, and
// their partner may not receive it in that one. Two people genuinely trying,
// neither feeling loved. Software can notice that mismatch — which is exactly
// what a person cannot see from inside, because from inside it is obvious you
// are showing love. You are. Just in your own language.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/memory/domain/love_languages.dart';

Act _gave(String text) => Act(text: text, by: Side.user);
Act _valued(String text) => Act(text: text, by: Side.partner);

void main() {
  group('reading an act', () {
    test('recognises the five languages from how people actually write', () {
      expect(classifyAct('le lavé el coche'), LoveLanguage.actsOfService);
      expect(classifyAct('le dije lo orgulloso que estoy de ella'),
          LoveLanguage.wordsOfAffirmation);
      expect(classifyAct('le llevé flores'), LoveLanguage.gifts);
      expect(classifyAct('salimos a cenar solos, sin teléfonos'),
          LoveLanguage.qualityTime);
      expect(classifyAct('estuvimos abrazados viendo la peli'),
          LoveLanguage.physicalTouch);
    });

    test('an act it cannot read is left unclassified, never guessed', () {
      // A wrong classification quietly skews the whole observation.
      expect(classifyAct('fuimos al súper'), isNull);
      expect(classifyAct(''), isNull);
    });
  });

  group('the observation', () {
    test('names the mismatch between what is given and what is valued', () {
      final o = observeLoveLanguages([
        _gave('le lavé el coche'),
        _gave('le arreglé la puerta'),
        _gave('le hice el desayuno'),
        _gave('le llené el tanque'),
        _valued('dijo que extraña que salgamos solos'),
        _valued('me pidió que apagáramos los teléfonos y platicáramos'),
        _valued('dijo que le gustó nuestra caminata juntos'),
      ]);

      expect(o, isNotNull);
      expect(o!.userGivesMost, LoveLanguage.actsOfService);
      expect(o.partnerValuesMost, LoveLanguage.qualityTime);
    });

    test('reads as an observation, never as an instruction', () {
      final o = observeLoveLanguages([
        _gave('le lavé el coche'),
        _gave('le arreglé la puerta'),
        _gave('le hice el desayuno'),
        _valued('dijo que extraña que salgamos solos'),
        _valued('quiere que platiquemos sin teléfonos'),
        _valued('le gustó la caminata juntos'),
      ]);

      final text = o!.describe();
      expect(text, contains('actos de servicio'));
      expect(text, contains('tiempo de calidad'));
      // No imperative, no task, no deadline. It states what is; the user draws
      // their own conclusion.
      for (final imperative in ['deberías', 'tienes que', 'recuerda', 'haz ']) {
        expect(text.toLowerCase(), isNot(contains(imperative)));
      }
    });

    test('says nothing when both are already in the same language', () {
      // There is no misunderstanding to point at. Speaking up anyway would be
      // noise, and noise is what gets the whole feature muted.
      final o = observeLoveLanguages([
        _gave('le lavé el coche'),
        _gave('le arreglé la puerta'),
        _gave('le hice el desayuno'),
        _valued('dijo que le encanta cuando le arreglo cosas'),
        _valued('agradeció que le hiciera el desayuno'),
        _valued('dijo que le ayudó que lavara el coche'),
      ]);

      expect(o, isNull);
    });
  });

  group('what it refuses to do', () {
    test('stays silent on too little evidence', () {
      // Two data points are an anecdote. Announcing a pattern from them is how
      // software earns distrust on something this personal.
      final o = observeLoveLanguages([
        _gave('le lavé el coche'),
        _valued('dijo que extraña que salgamos solos'),
      ]);

      expect(o, isNull);
    });

    test('stays silent when only one side was recorded', () {
      final o = observeLoveLanguages([
        _gave('le lavé el coche'),
        _gave('le arreglé la puerta'),
        _gave('le hice el desayuno'),
        _gave('le llené el tanque'),
      ]);

      expect(o, isNull);
    });

    test('stays silent when neither side has a clear leaning', () {
      // A tie is not a finding.
      final o = observeLoveLanguages([
        _gave('le lavé el coche'),
        _gave('le dije que la admiro'),
        _gave('le llevé flores'),
        _valued('le gustaron las flores'),
        _valued('dijo que le sirvió que lavara el coche'),
        _valued('le gustó que le dijera lo que pienso de ella'),
      ]);

      expect(o, isNull);
    });

    test('never produces a score, a streak or a target', () {
      final o = observeLoveLanguages([
        _gave('le lavé el coche'),
        _gave('le arreglé la puerta'),
        _gave('le hice el desayuno'),
        _valued('extraña que salgamos solos'),
        _valued('quiere que platiquemos sin teléfonos'),
        _valued('le gustó la caminata juntos'),
      ]);

      final text = o!.describe();
      for (final gamified in ['%', 'racha', 'puntos', 'meta', 'objetivo']) {
        expect(text.toLowerCase(), isNot(contains(gamified)));
      }
    });
  });
}
