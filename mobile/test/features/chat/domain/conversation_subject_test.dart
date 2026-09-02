// WHO the conversation is about right now.
//
// Asked for directly: "ese chat tiene que estar aprendiendo de qué le estamos
// platicando de esa misma persona, o si cambiamos de repente a otra persona,
// sepa de qué estamos hablando, para evitar que vaya a guardar cosas de una
// persona en otra".
//
// That last clause is the whole feature. Telling Axi about Juan's daughter and
// having it stored against Laura is not a small bug: the app's promise is that
// it remembers your people correctly, and a memory that quietly mixes two
// people up is worse than one that forgot.
//
// So this decides the subject IN CODE, never by asking the model to keep
// track. A ~2B model loses the thread within three turns, and this project has
// already learned that lesson twice — the decision belongs in Dart.
//
// The rule that matters most: when it is not SURE, it says so. A null subject
// means "ask the user who this is about", never "guess the last one".
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/conversation_subject.dart';

void main() {
  final t0 = DateTime(2026, 8, 19, 12, 0);
  const known = ['Juan', 'Laura', 'Sofía', 'Ana'];

  ConversationSubject? resolve(
    String message, {
    ConversationSubject? previous,
    Duration since = Duration.zero,
  }) =>
      resolveConversationSubject(
        message: message,
        knownPeople: known,
        previous: previous,
        now: t0.add(since),
      );

  group('a name in the message decides it', () {
    test('a known name becomes the subject', () {
      expect(resolve('Juan tiene dos hijos')!.name, 'Juan');
    });

    test('an accented known name is matched', () {
      expect(resolve('Sofía cumple años en marzo')!.name, 'Sofía');
    });

    test('a name typed without its accent still matches the known one', () {
      // People do not type accents on a phone keyboard.
      expect(resolve('Sofia entra a la escuela')!.name, 'Sofía');
    });

    test('a name nobody has mentioned before is still a subject', () {
      // Meeting someone new is the main way this gets used.
      expect(resolve('Conocí a Roberto en la oficina')!.name, 'Roberto');
    });
  });

  group('it refuses to guess', () {
    test('two names in one message is ambiguous, not the first one', () {
      // "Juan me contó que Laura se casa" is about Laura, or about Juan, and
      // picking one silently is how facts land on the wrong person.
      expect(resolve('Juan me contó que Laura se casa'), isNull);
    });

    test('no name and no previous subject is nobody', () {
      expect(resolve('tiene tres hijos'), isNull);
    });

    test('a stale subject is not reused', () {
      // An hour later, "su esposa se llama Marta" is almost certainly about
      // someone else. Carrying the old subject forward would attribute it
      // confidently and wrongly.
      final previous = ConversationSubject(name: 'Juan', at: t0);

      expect(
        resolve('tiene tres hijos',
            previous: previous, since: const Duration(hours: 1)),
        isNull,
      );
    });
  });

  group('the thread holds while it is still the same conversation', () {
    test('a follow-up with no name keeps the subject', () {
      final previous = ConversationSubject(name: 'Juan', at: t0);

      final subject = resolve('tiene dos hijos',
          previous: previous, since: const Duration(minutes: 1));

      expect(subject!.name, 'Juan');
    });

    test('a pronoun keeps the subject', () {
      final previous = ConversationSubject(name: 'Juan', at: t0);

      expect(
        resolve('él trabaja en Puebla',
                previous: previous, since: const Duration(minutes: 2))!
            .name,
        'Juan',
      );
    });

    test('a place is not mistaken for a person', () {
      // "Juan vive en Puebla" must stay about Juan. A capitalised word is not
      // a person just because it is capitalised, and attributing a life to a
      // city is the same class of mistake as attributing it to the wrong
      // friend.
      final previous = ConversationSubject(name: 'Juan', at: t0);

      expect(
        resolve('él trabaja en Puebla',
                previous: previous, since: const Duration(minutes: 2))!
            .name,
        'Juan',
      );
    });

    test('naming someone else switches the subject', () {
      final previous = ConversationSubject(name: 'Juan', at: t0);

      expect(
        resolve('Laura cambió de trabajo',
                previous: previous, since: const Duration(minutes: 1))!
            .name,
        'Laura',
      );
    });

    test('the timestamp advances so the window follows the conversation', () {
      // Otherwise a long chat about one person would go stale mid-sentence.
      final previous = ConversationSubject(name: 'Juan', at: t0);

      final subject = resolve('tiene dos hijos',
          previous: previous, since: const Duration(minutes: 5));

      expect(subject!.at, t0.add(const Duration(minutes: 5)));
    });
  });

  group('what the user is told when it does not know', () {
    test('an ambiguous subject asks, naming the candidates', () {
      final question = askWhoThisIsAbout(['Juan', 'Laura']);

      expect(question, contains('Juan'));
      expect(question, contains('Laura'));
      expect(question, contains('?'));
    });

    test('with no candidates it still asks rather than assuming', () {
      expect(askWhoThisIsAbout(const []), contains('?'));
    });
  });

  group('a question is not a statement about someone', () {
    test('asking about a person sets the subject but stores nothing', () {
      // "¿quién es Laura?" is about Laura, and it must NOT be recorded as a
      // fact about her.
      final subject = resolve('¿quién es Laura?');

      expect(subject!.name, 'Laura');
      expect(subject.isQuestion, isTrue);
    });

    test('a statement is marked as one', () {
      expect(resolve('Laura tiene dos hijos')!.isQuestion, isFalse);
    });
  });

  group('a follow-up is attributed to whoever the thread is about', () {
    // The point of tracking a subject at all. "tiene dos hijos" carries no
    // name, so the capture layer had nothing to attach it to — and a fact with
    // no owner either gets dropped or, worse, lands on whoever was handy.

    test('a nameless statement is rewritten to name the subject', () {
      final subject = ConversationSubject(name: 'Juan', at: t0);

      expect(attributeToSubject('tiene dos hijos', subject),
          'Juan tiene dos hijos');
    });

    test('a pronoun is replaced, not doubled up', () {
      final subject = ConversationSubject(name: 'Juan', at: t0);

      // "él Juan trabaja en Puebla" would be nonsense to store and to read.
      expect(attributeToSubject('él trabaja en Puebla', subject),
          'Juan trabaja en Puebla');
    });

    test('a message that already names the subject is left alone', () {
      final subject = ConversationSubject(name: 'Juan', at: t0);

      expect(attributeToSubject('Juan tiene dos hijos', subject),
          'Juan tiene dos hijos');
    });

    test('with no subject the message is untouched', () {
      // Never invent an owner. Unattributed is recoverable; misattributed is
      // not, because nobody goes looking for a fact filed under the wrong
      // person.
      expect(attributeToSubject('tiene dos hijos', null), 'tiene dos hijos');
    });

    test('a question is never rewritten', () {
      // "¿cuántos hijos tiene?" is a question about the subject, not a fact to
      // store about them.
      final subject =
          ConversationSubject(name: 'Juan', at: t0, isQuestion: true);

      expect(attributeToSubject('¿cuántos hijos tiene?', subject),
          '¿cuántos hijos tiene?');
    });

    test('the possessive keeps its meaning', () {
      final subject = ConversationSubject(name: 'Juan', at: t0);

      // "su esposa se llama Marta" is Juan's wife, and it has to READ that way
      // once the name is in it.
      expect(attributeToSubject('su esposa se llama Marta', subject),
          'la esposa de Juan se llama Marta');
    });
  });

  group('a question is never a capture', () {
    // Measured on the test Pixel: "a qué hora me pesé ayer" was read as a
    // WEIGHT ENTRY, because "pesé" looks like one to the capture triage, and
    // the turn went to the model — which answered 15:16 for something logged
    // at 09:16.
    //
    // The ordering rule this pins: anything that ASKS is answered before
    // anything that stores gets a look at it.
    test('asking about a time is recognised as a question', () {
      final subject = resolveConversationSubject(
        message: '¿a qué hora me pesé ayer?',
        knownPeople: const [],
        now: t0,
      );

      // No person named, so no subject — and crucially nothing to attribute a
      // weight to either.
      expect(subject, isNull);
    });

    test('a question mark alone marks the turn', () {
      final subject = resolveConversationSubject(
        message: '¿Juan tiene hijos?',
        knownPeople: const ['Juan'],
        now: t0,
      );

      expect(subject!.isQuestion, isTrue,
          reason: 'a question about Juan must not be stored as a fact');
    });
  });

  group('the user\'s own life is not filed under the person being discussed',
      () {
    // MEDIDO: con "Tere" como sujeto ACTIVO, el turno siguiente salía
    // reescrito con su nombre delante — TODOS ellos, no solo los que se
    // apoyaban en el hilo:
    //
    //   FACT domain=finance label=Tere gaste 200 pesos en gasolina
    //   FACT domain=health  label=Tere me duele la cabeza
    //
    // Es decir: los gastos y los síntomas del PROPIO usuario archivados a
    // nombre de su hermana. Ese es exactamente el misfile que este archivo
    // existe para evitar, y es peor que no archivar nada, porque nadie va a
    // ir a buscar ahí.
    //
    // Estos tests encadenan TURNOS con un sujeto vivo, que es la única forma
    // de reproducirlo: con `knownPeople` vacío y sin sujeto previo el defecto
    // no aparece, y así fue como se escapó.
    const people = ['Tere', 'Juan'];

    ConversationSubject? turn(String message,
            {ConversationSubject? previous, Duration since = Duration.zero}) =>
        resolveConversationSubject(
          message: message,
          knownPeople: people,
          previous: previous,
          now: t0.add(since),
        );

    /// Turno 1 nombra a Tere; turno 2 es lo que el usuario escribe después.
    String secondTurn(String message) {
      final first = turn('Ayer vi a Tere');
      expect(first?.name, 'Tere', reason: 'el arnés debe dejar a Tere activa');
      final second =
          turn(message, previous: first, since: const Duration(minutes: 1));
      expect(second?.name, 'Tere',
          reason: 'el hilo sigue vivo: el defecto solo aparece así');
      return attributeToSubject(message, second);
    }

    test('un gasto en primera persona sigue siendo del usuario', () {
      expect(secondTurn('gaste 200 pesos en gasolina'),
          'gaste 200 pesos en gasolina');
    });

    test('un gasto con acento tampoco cambia de dueño', () {
      expect(secondTurn('gasté 200 pesos en gasolina'),
          'gasté 200 pesos en gasolina');
    });

    test('un síntoma en primera persona sigue siendo del usuario', () {
      expect(secondTurn('me duele la cabeza'), 'me duele la cabeza');
    });

    test('un peso y una carrera propios no se archivan en la hermana', () {
      expect(secondTurn('peso 80 kilos'), 'peso 80 kilos');
      expect(secondTurn('corrí 5 km'), 'corrí 5 km');
      expect(secondTurn('tengo cita con el dentista'),
          'tengo cita con el dentista');
    });

    // Y la razón por la que el prepend existe TIENE que seguir en pie: "su
    // hijo Mateo tiene 8" / "tiene dos hijos" no nombran a nadie, y sin el
    // sujeto del hilo se guardaban colgadas de nadie o de quien estuviera a
    // mano.
    test('una frase que se apoya en el hilo sigue nombrando al sujeto', () {
      expect(secondTurn('tiene dos hijos'), 'Tere tiene dos hijos');
      expect(secondTurn('vive en Monterrey'), 'Tere vive en Monterrey');
      expect(secondTurn('trabaja en Bimbo'), 'Tere trabaja en Bimbo');
    });

    test('el posesivo de tercera persona sigue reescribiéndose', () {
      // "su" es una marca EXPLÍCITA de tercera persona y gana siempre: se
      // evalúa antes que cualquier heurística de primera persona.
      expect(secondTurn('su esposa se llama Marta'),
          'la esposa de Tere se llama Marta');
    });
  });

  group('an order to Axi names nobody', () {
    // MEDIDO en el Pixel (build 921): "Cuenta del 1 al 30 separados por comas"
    // dejó "Cuenta" como sujeto de la conversación. Desde ahí cada turno salía
    // reescrito con ese nombre delante ("Cuenta gaste 200 pesos en gasolina"),
    // y como la frase volvía a empezar por un imperativo, la captura
    // determinista dejó de dispararse para TODO lo que vino después.
    test('a leading imperative is not a name', () {
      expect(namesIn('Cuenta del 1 al 30 separados por comas'), isEmpty);
      expect(
        resolveConversationSubject(
          message: 'Cuenta del 1 al 30 separados por comas',
          knownPeople: const [],
          now: t0,
        ),
        isNull,
      );
    });

    test('and it does not steal a thread that was already running', () {
      final juan = ConversationSubject(name: 'Juan', at: t0);
      final after = resolve('Cuéntame un chiste',
          previous: juan, since: const Duration(minutes: 1));

      // Sigue siendo Juan (o nadie), pero nunca "Cuéntame".
      expect(after?.name, isNot('Cuéntame'));
    });

    test('and the turn after it is not rewritten with that word in front', () {
      final poisoned = resolveConversationSubject(
        message: 'Cuenta del 1 al 30 separados por comas',
        knownPeople: const [],
        now: t0,
      );

      expect(attributeToSubject('gaste 200 pesos en gasolina', poisoned),
          'gaste 200 pesos en gasolina');
    });
  });
}
