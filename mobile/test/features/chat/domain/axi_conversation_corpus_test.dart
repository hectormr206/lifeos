// A corpus of REAL messages, and what must be true of the prompt for each.
//
// Asked for after the chat answered its own instructions: "múltiples ejemplos
// de todo lo que se guarda hoy en Axi, sus relaciones y cómo responde a cada
// una, simulando varios tipos de usuarios y sus diferentes formas de enviar
// mensajes".
//
// WHAT THIS SUITE CAN AND CANNOT PROVE. It runs with no model, so it proves the
// CONTRACT: what reaches the model, in what order, with which rules attached.
// It cannot prove the answer is good — that needs a live model, and there is a
// second harness for it. Keeping the line visible matters: a green run here
// means "we asked correctly", never "it replied well".
//
// The corpus is deliberately messy, because real input is. Voice dictation with
// no punctuation, typos, mixed Spanish and English, one-word replies,
// statements that are not questions, corrections of something said earlier, and
// the health and relationship data the app actually stores.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/axi_prompt_context.dart';

/// One realistic turn: what the user typed, and how they typed it.
class Turn {
  const Turn(this.style, this.message, {this.language = 'es'});
  final String style;
  final String message;
  final String language;
}

const corpus = <Turn>[
  // ── Statements: the shape that broke it. No question to answer, so a weak
  // prompt lets the model fall back to acknowledging its instructions.
  Turn('afirmación simple', 'mi esposa se llama Ana'),
  Turn('afirmación con relación', 'Ana es la mamá de Sofía'),
  Turn('afirmación de salud', 'hoy pesé 82 kilos'),
  Turn('afirmación de rutina', 'los martes entreno a las 7'),

  // ── Voice dictation: no punctuation, no capitals, run-on.
  Turn('dictado sin puntuación',
      'oye recordame que mañana tengo que llevar a sofia al dentista a las 4'),
  Turn('dictado largo',
      'estuve pensando que deberia bajarle al cafe porque ultimamente ando '
      'durmiendo mal y creo que es por eso'),

  // ── Typos and phone keyboards.
  Turn('con erratas', 'cual fu emi presion la semana pasda'),
  Turn('sin acentos', 'cuanto pese el mes pasado'),

  // ── Terse. A one-word turn is the hardest thing to answer well.
  Turn('una palabra', 'y?'),
  Turn('dos palabras', 'y ayer'),

  // ── Mixed language, which is how bilingual people actually write.
  Turn('mezcla es/en', 'agenda un meeting con Ana el jueves'),

  // ── Corrections: the user fixing something already stored.
  Turn('corrección', 'no, dije 82 no 92'),
  Turn('corrección de relación', 'Sofía no es mi hermana, es mi hija'),

  // ── Questions against memory.
  Turn('pregunta a memoria', '¿cómo se llama mi esposa?'),
  Turn('pregunta temporal', '¿qué tengo mañana?'),
  Turn('pregunta de salud', '¿cómo viene mi presión este mes?'),

  // ── Things the app must refuse to invent.
  Turn('pide dato inexistente', '¿cuánto pesaba en 2019?'),

  // ── English install.
  Turn('english statement', 'my wife is called Ana', language: 'en'),
  Turn('english question', 'what do I have tomorrow?', language: 'en'),
];

void main() {
  final now = DateTime(2026, 8, 18, 9, 0);

  String promptFor(Turn turn, {String memory = '', String? name}) =>
      decorateWithAxiContext(
        message: turn.message,
        languageCode: turn.language,
        now: now,
        memoryBlock: memory,
        userName: name,
      );

  group('every message in the corpus is asked correctly', () {
    for (final turn in corpus) {
      test('${turn.style}: "${turn.message}"', () {
        final prompt = promptFor(turn);

        // 1. The user's words arrive INTACT. Trimming, normalising or
        //    "cleaning" them would quietly change what was asked — a typo is
        //    information about how this person writes.
        expect(prompt, contains(turn.message));

        // 2. They are the LAST thing in the prompt: recency is what a small
        //    model weighs most.
        expect(prompt.trimRight().endsWith(turn.message), isTrue,
            reason: 'anything after the message competes with it');

        // 3. They are labelled as the turn to answer, not left to blend into
        //    the instructions above.
        expect(prompt, contains(turn.language == 'en' ? 'MESSAGE' : 'MENSAJE'));

        // 4. The rules that stop the reported failure are attached.
        final rules = prompt.toLowerCase();
        expect(
          rules,
          contains(turn.language == 'en'
              ? 'do not introduce yourself'
              : 'no te presentes'),
        );

        // 5. The date is present, so "mañana" and "la semana pasada" mean
        //    something. Half this corpus is time-relative.
        expect(prompt, contains('2026'));
      });
    }
  });

  group('memory reaches the model when there is any', () {
    test('the memory block sits before the message, never after', () {
      // After the message it would read as a continuation of what the user
      // said — the model would treat stored facts as this turn's words.
      final prompt = promptFor(
        const Turn('pregunta a memoria', '¿cómo se llama mi esposa?'),
        memory: 'MEMORIA RELEVANTE\nesposa: Ana',
      );

      expect(prompt.indexOf('MEMORIA RELEVANTE'),
          lessThan(prompt.indexOf('¿cómo se llama mi esposa?')));
    });

    test('an empty memory block adds nothing at all', () {
      // An empty "MEMORIA RELEVANTE" heading would tell the model it has
      // memory and that it is empty — which is not the same as having none,
      // and invites "no tengo tus datos".
      final withNone = promptFor(const Turn('x', 'hola'), memory: '   ');
      final withSome = promptFor(const Turn('x', 'hola'),
          memory: 'MEMORIA RELEVANTE\nesposa: Ana');

      // The phrase also appears inside the RULES ("si arriba aparece un bloque
      // MEMORIA RELEVANTE"), so the test counts occurrences rather than
      // asserting absence — the rule must stay, the empty block must not
      // appear.
      int count(String text) => 'MEMORIA RELEVANTE'.allMatches(text).length;
      expect(count(withNone), 1);
      expect(count(withSome), 2);
    });

    test('the rule against saying "no tengo acceso" is always attached', () {
      final prompt = promptFor(const Turn('x', '¿cuánto pesé ayer?'));

      expect(prompt, contains('no tengo acceso'));
    });

    test('the rule against inventing data is always attached', () {
      // The corpus includes "¿cuánto pesaba en 2019?" precisely because the
      // honest answer is "no lo sé". Health data especially.
      final prompt = promptFor(const Turn('x', '¿cuánto pesaba en 2019?'));

      expect(prompt.toLowerCase(), contains('inventes'));
    });
  });

  group('findings from the real device, pinned so they cannot come back', () {
    // Both observed on the test Pixel running 836, driven over adb.

    test('it is told to speak in the SECOND person', () {
      // Observed: "¿cuánto pesaba Héctor en 2019?" — talking ABOUT the user
      // instead of TO him. Using someone's name as if they were a third party
      // reads as a case file, not a conversation.
      final prompt = promptFor(
        const Turn('x', '¿cuánto pesaba en 2019?'),
        name: 'Héctor',
      );

      expect(prompt, contains('"tú"'));
      expect(prompt.toLowerCase(), contains('nunca en tercera'));
    });

    test('an elliptical turn must follow the SAME topic', () {
      // Observed: after talking about weight, "y ayer" was answered with what
      // he ate. It resolved the ellipsis against memory — but against the
      // wrong thread.
      final prompt = promptFor(const Turn('x', 'y ayer'));

      expect(prompt.toLowerCase(), contains('mismo tema'));
    });

    test('with no clear topic it must ask, not guess', () {
      final prompt = promptFor(const Turn('x', '¿y?'));

      expect(prompt.toLowerCase(), contains('pregunta a qué se refiere'));
    });

    test('the English install gets the same two rules', () {
      final prompt = promptFor(
        const Turn('x', 'and yesterday?', language: 'en'),
        name: 'Héctor',
      );

      expect(prompt.toLowerCase(), contains('second person'));
      expect(prompt.toLowerCase(), contains('same topic'));
    });
  });

  group('memory is the USER\'s life, never Axi\'s', () {
    // Measured on the test Pixel with 839: "¿cómo se llama mi esposa?" came
    // back as "Ana es mi esposa." — Axi claiming a wife. The memory had stored
    // the user's own first-person wording and the model repeated it verbatim,
    // producing a sentence that is simply false about itself.

    test('it is told that "mi X" in memory means the USER\'s X', () {
      final prompt = promptFor(const Turn('x', '¿cómo se llama mi esposa?'));

      expect(prompt, contains('jamás "mi esposa"'));
    });

    test('it is told it owns none of these facts', () {
      final prompt = promptFor(const Turn('x', '¿cuánto pesé?'));

      expect(prompt.toLowerCase(), contains('tú no tienes esposa'));
    });

    test('a relationship question is answered from the stored bond', () {
      // Also measured: "¿qué relación tengo con Ana?" asked for more context
      // while the bond was sitting in memory.
      final prompt = promptFor(const Turn('x', '¿qué relación tengo con Ana?'));

      expect(prompt.toLowerCase(), contains('si el nombre está en la memoria'));
    });

    test('English gets the same rules', () {
      final prompt =
          promptFor(const Turn('x', 'what is my wife called?', language: 'en'));

      expect(prompt, contains('never'));
      expect(prompt.toLowerCase(), contains('if the name is in memory'));
    });
  });

  group('a bond belongs to ONE person', () {
    // Measured on 845: "¿qué relación tengo con Sofía?" answered "Tu relación
    // con Sofía es esposa." Sofía had never been stored, so the model took the
    // only bond in the block and attached it to the wrong person — inventing a
    // family relationship about someone real.
    test('it is told never to lend another person\'s bond', () {
      final prompt = promptFor(const Turn('x', '¿qué relación tengo con Sofía?'));

      expect(prompt.toLowerCase(), contains('una persona concreta'));
      expect(prompt.toLowerCase(), contains('no sabes quién es'));
      // And the POSITIVE half, which the first wording buried: over-weighting
      // the refusal made it answer "no tengo información" about someone it
      // demonstrably knew.
      expect(prompt.toLowerCase(), contains('si el nombre está en la memoria'));
    });

    test('it ranks that with inventing health data', () {
      final prompt = promptFor(const Turn('x', '¿quién es Roberto?'));

      expect(prompt.toLowerCase(), contains('inventar un parentesco'));
    });
  });

  group('the person is addressed as themselves', () {
    test('a known name is passed through with its meaning', () {
      final prompt = promptFor(const Turn('x', 'agenda algo'), name: 'Héctor');

      expect(prompt, contains('Héctor'));
      // "yo"/"mi" has to resolve to the user, or a self-reference silently
      // becomes a reference to nobody.
      expect(prompt, contains('"yo"'));
      // And the model must be told to answer in the second person.
      expect(prompt, contains('hablando CON él'));
    });

    test('an unknown name adds no line at all', () {
      final prompt = promptFor(const Turn('x', 'hola'));

      expect(prompt, isNot(contains('El usuario se llama')));
    });
  });
}
