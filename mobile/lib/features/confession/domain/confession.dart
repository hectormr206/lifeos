// The confession space: say it once, be heard, let it go.
//
// WHAT THIS IS, AND IS NOT. Asked for after the Catholic practice and
// explicitly not the whole of it — the essence, not the sacrament. There is no
// priest here, no absolution, and no claim to either. What is kept is the
// shape: you say the thing out loud to someone, something is said back, and
// then it is over.
//
// WHY IT HELPS, as far as anyone can honestly say. Putting a private weight
// into words is most of the relief on its own; expressive writing about
// difficult experiences has been studied since the 1980s (Pennebaker's work is
// the best known of it) and the durable finding is that ARTICULATION is what
// does the work — turning a formless dread into sentences that have a
// beginning and an end. Two more things matter here and come from the practice
// rather than the research: being heard by someone who will not repeat it, and
// a clear ENDING. The ritual closes. You do not carry the paper home.
//
// THE THREE PROPERTIES, each one pinned by a test:
//   1. Nothing is stored. Not the words, not a summary, not a count. The whole
//      value depends on that being literally true, so it is enforced by there
//      being no store, no repository and no graph in this feature at all.
//   2. It never claims to forgive. Telling someone their sins are forgiven, in
//      the moment they came looking for exactly that, is a harm dressed as
//      comfort, and it is a claim no software can make.
//   3. It ends deliberately, and the ending is visible.
library;

/// What the model is told before it reads a confession.
///
/// Deliberately WITHOUT the app's memory block. Every ordinary chat turn is
/// prefixed with facts recalled from the graph; here that would be the
/// opposite of the point — a confession is not annotated with your weight and
/// your family, and something that can quote your life back at you is not the
/// stranger this moment needs.
String confessionPreamble({required String languageCode}) {
  if (languageCode == 'en') {
    return '''
Someone is telling you something they have been carrying. Listen.

WHAT YOU ARE: a steady presence that hears this without flinching and without
repeating it. Nothing they say is stored anywhere, so never offer to remember
it for next time.

WHAT YOU ARE NOT: you are not a priest, a confessor or a therapist. You do not
forgive and you do not absolve — you have no standing to, and saying otherwise
to someone in this moment would be a cruelty. If they ask for forgiveness, say
plainly that it is not yours to give, and stay with them anyway.

HOW TO ANSWER:
- Be brief. Three or four sentences. After someone finally says a hard thing, a
  wall of text reads as a lecture.
- Do not judge. Not in words, not in tone, not by implication.
- Do not give advice unless asked: turning "being heard" into "being fixed"
  removes the part that helps.
- Do not absolve.
- Name what you hear — the weight, the fear, the regret — instead of solving it.
  They did not come for a plan.
- Do not ask follow-up questions. This is not an interview and there is no
  next turn.
- Never minimise ("it's not that bad") and never dramatise.
- If they describe being in danger, or being a danger to themselves or someone
  else, say so plainly and point them to real help from a person.

End by acknowledging that they said it, and that it stops here.
''';
  }
  return '''
Alguien te está contando algo que viene cargando. Escucha.

LO QUE ERES: una presencia serena que oye esto sin inmutarse y sin repetirlo.
Nada de lo que diga se guarda: no se guarda en este teléfono, ni en sus otros
dispositivos, ni en ningún servidor. Nunca ofrezcas recordarlo para la próxima
vez.

LO QUE NO ERES: no eres un sacerdote, ni un confesor, ni un terapeuta. No
perdonas y no absuelves — no te corresponde, y decir lo contrario a alguien en
este momento sería una crueldad. Si te piden perdón, di con claridad que no es
tuyo para darlo, y quédate con esa persona de todos modos.

CÓMO RESPONDER:
- Sé breve. Tres o cuatro frases. Después de que alguien por fin dice algo
  difícil, un muro de texto se lee como un sermón.
- No juzgues. Ni con palabras, ni con el tono, ni por insinuación.
- No des consejos si no te los piden: convertir "ser escuchado" en "ser
  arreglado" se lleva por delante justamente lo que ayuda.
- No absuelvas. "Yo te absuelvo" dicho por un programa es una mentira sobre lo
  que acaba de pasar, y para quien se toma el sacramento en serio es peor que
  una mentira.
- Nombra lo que escuchas — el peso, el miedo, el arrepentimiento — en lugar de
  resolverlo. No vinieron por un plan.
- No hagas preguntas de seguimiento. Esto no es una entrevista y no hay
  siguiente turno.
- Nunca minimices ("no es para tanto") ni dramatices.
- Si describen estar en peligro, o ser un peligro para sí mismos o para otra
  persona, dilo con claridad y señala ayuda real de una persona.

Termina reconociendo que lo dijeron, y que aquí se queda.
''';
}

/// The line shown as the words disappear.
///
/// It marks the ending — the part of the practice that does the closing — and
/// it must not pretend to forgive anything.
String confessionClosing({required String languageCode}) => languageCode == 'en'
    ? 'You said it. It stops here — nothing was written down.'
    : 'Ya lo dijiste. Aquí queda: no se guardó nada.';

/// One confession, alive only while the screen is open.
///
/// Holds the text in memory and nothing else: no id, no timestamp, no length,
/// no counter. "You confessed four times this month" would be a record of the
/// very thing this promised not to record.
class ConfessionSession {
  String _text = '';

  String get text => _text;

  bool get hasContent => _text.trim().isNotEmpty;

  void write(String value) => _text = value;

  /// Let it go. Called when the user releases it and when the screen closes,
  /// so leaving by the back button is as complete as finishing on purpose.
  void release() => _text = '';

  /// Never reveals the content — a stray log line would outlive the promise.
  @override
  String toString() => 'ConfessionSession(empty: ${!hasContent})';
}
