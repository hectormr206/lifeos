// How DIFFERENT people actually talk, and whether the subject tracking holds.
//
// Asked for: "haz pruebas de todo esto... simulando cómo pueden hablar y
// expresarse varias personas diferentes de edad, sexo, rango social y demás
// cosas que influyan en la conversación".
//
// The reason this matters is narrow and concrete. The subject tracker decides
// WHO a fact belongs to, and it decides it from wording. A grandmother writing
// "mi nuera Marisol anda mala del estómago" and a teenager writing "la novia
// de mi carnal se puso mala" are the same claim in two registers, and the app
// has one shot at attributing it to the right person. Everything downstream —
// the brain, the recall, what Axi says about your family — inherits that
// decision.
//
// WHAT THIS PROVES: the attribution, not the storage. That a sentence about
// Marisol ends up about Marisol, and that a sentence about nobody in
// particular is not quietly filed under whoever spoke last.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/conversation_subject.dart';

/// One realistic speaker, and how they write.
class Speaker {
  const Speaker(this.who, this.turns);
  final String who;

  /// (message, the person it is ABOUT — null when nobody in particular)
  final List<(String, String?)> turns;
}

const speakers = <Speaker>[
  Speaker('abuela, 71, poca escritura digital, sin acentos ni puntuación', [
    ('mi nuera Marisol anda mala del estomago', 'Marisol'),
    ('ya tiene tres dias asi', 'Marisol'),
    ('le dije que fuera al doctor', 'Marisol'),
  ]),
  Speaker('adolescente, 16, jerga y abreviaturas', [
    ('bro Diego reprobó mate otra vez', 'Diego'),
    ('ya va como 3 veces', 'Diego'),
    ('su jefa lo va a matar', 'Diego'),
  ]),
  Speaker('profesionista, 34, escribe correcto y largo', [
    (
      'Ayer comí con Fernanda y me comentó que la ascendieron a gerente '
      'regional en su empresa.',
      'Fernanda'
    ),
    ('Se muda a Monterrey en noviembre.', 'Fernanda'),
  ]),
  Speaker('obrero, 48, dictado por voz, sin puntuación', [
    ('oye acuerdate que don Ramiro me presto la camioneta', 'Ramiro'),
    ('se la tengo que regresar el viernes', 'Ramiro'),
  ]),
  Speaker('señora, 58, mezcla temas en una sola frase', [
    ('mi hija Karen se fue a vivir sola y ando triste', 'Karen'),
    ('pero está feliz ella', 'Karen'),
  ]),
  Speaker('joven, 22, bilingüe, mezcla español e inglés', [
    ('mi roommate Andrea got a new job', 'Andrea'),
    ('she starts on monday', 'Andrea'),
  ]),
  Speaker('hombre, 40, habla de sí mismo, no de terceros', [
    ('hoy pesé 82 kilos', null),
    ('me duele la rodilla desde el martes', null),
  ]),
];

void main() {
  final t0 = DateTime(2026, 8, 19, 10);

  group('every speaker is understood the same way', () {
    for (final speaker in speakers) {
      test(speaker.who, () {
        ConversationSubject? subject;
        var minute = 0;

        for (final (message, expected) in speaker.turns) {
          minute += 1;
          subject = resolveConversationSubject(
            message: message,
            // Nobody is known yet: this is someone telling the app about
            // their people for the first time, which is the hard case.
            knownPeople: const [],
            now: t0.add(Duration(minutes: minute)),
            previous: subject,
          );

          expect(subject?.name, expected,
              reason: '"$message" was attributed to ${subject?.name}');
        }
      });
    }
  });

  group('the thing that must never happen', () {
    test('facts about two people never merge into one', () {
      // The failure the whole tracker exists to prevent, written as the
      // sequence that would produce it: talk about one person, switch, and
      // then say something with no name in it.
      var subject = resolveConversationSubject(
        message: 'Marisol anda mala del estómago',
        knownPeople: const [],
        now: t0,
      );
      expect(subject!.name, 'Marisol');

      subject = resolveConversationSubject(
        message: 'oye y Diego reprobó',
        knownPeople: const ['Marisol'],
        now: t0.add(const Duration(minutes: 1)),
        previous: subject,
      );
      expect(subject!.name, 'Diego', reason: 'the switch was missed');

      subject = resolveConversationSubject(
        message: 'ya van tres veces',
        knownPeople: const ['Marisol', 'Diego'],
        now: t0.add(const Duration(minutes: 2)),
        previous: subject,
      );
      expect(subject!.name, 'Diego',
          reason: 'a follow-up landed on the PREVIOUS person');
    });

    test('coming back much later does not inherit the old person', () {
      final morning = ConversationSubject(name: 'Marisol', at: t0);

      final evening = resolveConversationSubject(
        message: 'anda mala otra vez',
        knownPeople: const ['Marisol'],
        now: t0.add(const Duration(hours: 9)),
        previous: morning,
      );

      expect(evening, isNull,
          reason: 'nine hours later this is a guess, and guesses get filed '
              'under the wrong person');
    });
  });
}
