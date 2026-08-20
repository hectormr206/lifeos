// The prompt for the Desahogo space, and the one case where reflecting back is
// the wrong answer.
//
// See `confession.dart` for what this space is, what it refuses to be, and why
// articulation plus a clear ending is the part worth building.
library;

import 'confession.dart';

export 'confession.dart' show confessionClosing;

/// The full prompt for one thing said: the guidance, then their words.
String buildConfessionPrompt(String text, {required String languageCode}) =>
    '${confessionPreamble(languageCode: languageCode)}\n\n'
    '${languageCode == 'en' ? 'THEY SAID:' : 'LO QUE DIJO:'}\n$text';

/// First-person statements of intent to die. Deliberately narrow.
///
/// Over-triggering would turn every ordinary confession into a crisis screen,
/// and people stop using something that overreacts — which would cost exactly
/// the person this is meant to protect. So: intent about ONESELF, not the fear
/// of dying some day, not grief, not guilt.
final List<RegExp> _crisisPatterns = [
  RegExp(r'\b(quiero|deseo|pienso en)\s+(matarme|suicidarme|morirme)\b'),
  RegExp(r'\bya no quiero (vivir|seguir|estar aqu[ií])\b'),
  RegExp(r'\bme quiero (matar|morir)\b'),
  RegExp(r'\bacabar con mi vida\b'),
  RegExp(r'\b(voy a|quiero) quitarme la vida\b'),
  RegExp(r'\bpensar?\s+en\s+suicid'),
  RegExp(r'\bkill myself\b'),
  RegExp(r"\b(i want to|i'm going to|im going to) die\b"),
  RegExp(r'\bend my life\b'),
  RegExp(r"\bdon'?t want to (live|be here) (any\s?more|anymore)\b"),
];

/// A line to add when someone says they intend to end their life, or null.
///
/// This does NOT diagnose and does not stop the space from listening. It adds
/// one honest sentence: a program is not what someone in that state needs, and
/// pretending otherwise could cost them. No phone number is invented here —
/// naming a wrong one would be worse than naming none — beyond the emergency
/// number, which is the only one safe to state without knowing where they are.
String? confessionSafetyNote(String text, {required String languageCode}) {
  final lower = text.toLowerCase();
  final matches = _crisisPatterns.any((p) => p.hasMatch(lower));
  if (!matches) return null;

  return languageCode == 'en'
      ? 'Before anything else: what you just said matters more than this '
            'screen. I am a program, and this is the moment for a person. Call '
            'your local emergency number or a crisis line now, or tell someone '
            'you trust tonight — not tomorrow.'
      : 'Antes que nada: lo que acabas de decir importa más que esta pantalla. '
            'Soy un programa, y este es un momento para una persona. Llama ahora '
            'al número de emergencias de tu país o a una línea de crisis, o '
            'díselo hoy mismo a alguien en quien confíes — no mañana.';
}

/// How much of a confession reaches the model.
///
/// The engine holds 4096 tokens — in Spanish, roughly twelve thousand
/// characters, and the guidance above already spends some of that. Ten
/// thousand leaves the model room to answer.
///
/// Someone speaking says about seven hundred characters a minute, so this is
/// around fifteen minutes of talking. The RECORDING is never cut: stopping
/// someone mid-sentence is the opposite of what this space is for. Only what
/// reaches the model is trimmed.
const int kDesahogoMaxChars = 10000;

/// True when [text] had to be trimmed to fit.
///
/// The caller must SAY so. A person reading a reply about the last few minutes
/// would otherwise take it as a verdict on the whole thing.
bool wasTrimmedForDesahogo(String text) => text.length > kDesahogoMaxChars;

/// The part of a long confession the model reads.
///
/// The END, not the beginning: people open with context and close with the
/// feeling. Keeping the opening would answer the setup and miss what they
/// actually came to say. Cut at a sentence boundary where there is one, so the
/// model never starts mid-word.
String trimForDesahogo(String text) {
  if (!wasTrimmedForDesahogo(text)) return text;
  final tail = text.substring(text.length - kDesahogoMaxChars);
  final boundary = tail.indexOf(RegExp(r'[.!?…]\s+'));
  if (boundary < 0 || boundary > 400) return tail.trimLeft();
  return tail.substring(boundary + 1).trimLeft();
}
