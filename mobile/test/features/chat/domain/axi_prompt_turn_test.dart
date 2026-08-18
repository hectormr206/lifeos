// Making the user's message unmistakably the thing to answer.
//
// Reported: telling the chat his wife's name got back "Entendido. Soy Axi, el
// asistente personal de IA de Héctor. Estoy listo para responder." — the model
// answering its own instructions instead of the person.
//
// The cause is structural. `flutter_gemma` has no system role (`Message.text`
// takes `isUser` and nothing else), so the persona, the date, the memory block
// and the message all arrive as ONE user turn. A ~2B model handed a long
// instruction block followed by a short STATEMENT — not a question — has
// nothing to answer and falls back to acknowledging the instructions.
//
// So the prompt has to mark the message as the turn to answer, and say what to
// do with a statement.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/axi_prompt_context.dart';

void main() {
  final now = DateTime(2026, 8, 18, 9, 0);

  String prompt(String message) => decorateWithAxiContext(
        message: message,
        languageCode: 'es',
        now: now,
      );

  test('the user message is the LAST thing in the prompt', () {
    // Recency carries the most weight for a small model: whatever sits at the
    // end is what it answers.
    final text = prompt('mi esposa se llama Ana');

    expect(text.trimRight().endsWith('mi esposa se llama Ana'), isTrue);
  });

  test('the message is labelled, not just appended', () {
    // Unlabelled, a statement blends into the instruction block above it and
    // reads as more context rather than as a turn.
    final text = prompt('mi esposa se llama Ana');

    expect(text, contains('MENSAJE'));
  });

  test('it is told not to introduce itself', () {
    // The exact failure: a self-introduction instead of a reply.
    final text = prompt('hola');

    expect(text.toLowerCase(), contains('no te presentes'));
  });

  test('it is told how to handle a statement, not only a question', () {
    final text = prompt('mi esposa se llama Ana');

    expect(text.toLowerCase(), contains('afirmación'));
  });

  test('the persona and the date are still there', () {
    // The fix must not cost what the preamble already did.
    final text = prompt('hola');

    expect(text, contains('Eres Axi'));
    expect(text, contains('2026'));
  });

  test('a memory block still lands before the message', () {
    final text = decorateWithAxiContext(
      message: '¿cuánto pesé ayer?',
      languageCode: 'es',
      now: now,
      memoryBlock: 'MEMORIA RELEVANTE\npeso 80 kg',
    );

    expect(text.indexOf('MEMORIA RELEVANTE'),
        lessThan(text.indexOf('¿cuánto pesé ayer?')));
  });

  test('English installs get the English wording', () {
    final text = decorateWithAxiContext(
      message: 'my wife is called Ana',
      languageCode: 'en',
      now: now,
    );

    expect(text.toLowerCase(), contains('do not introduce yourself'));
    expect(text, contains('MESSAGE'));
  });
}
