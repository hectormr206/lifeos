import 'package:intl/intl.dart';

/// Builds the concise system preamble prepended to every on-device Axi turn
/// (i18n + "Axi knows now" slices).
///
/// Two responsibilities, both minimal so they never disturb the tuned sampling
/// or the FIFO queue:
///   1. LANGUAGE: a one-line instruction so Axi always replies in the selected
///      language ("Responde SIEMPRE en español." / "Always respond in English.").
///   2. CURRENT DATE/TIME: the device-local now, localized to the same locale,
///      so Axi can reason about "today"/"now".
///
/// The [now] is passed in (never read here) so the caller supplies it via the
/// `Clock` seam — the future timezone slice overrides that clock alone.
///
/// Adding a language = one more case in [_languageLine]; the datetime line is
/// already locale-driven.
String buildAxiPromptPreamble({required String languageCode, required DateTime now}) {
  final dateTimeText = formatPromptDateTime(languageCode: languageCode, now: now);
  return '${_languageLine(languageCode)}\n'
      '${_dateTimeLine(languageCode)}: $dateTimeText.';
}

/// Prepends the preamble to a user [message] (blank line between), the exact
/// text handed to the engine's `generate` / `generateWithImages`.
String withAxiPromptPreamble({
  required String message,
  required String languageCode,
  required DateTime now,
}) =>
    '${buildAxiPromptPreamble(languageCode: languageCode, now: now)}\n\n$message';

/// Axi's CONCISE persona + response guidance (roadmap SLICE C1), ported and
/// compressed from the laptop `axi/src/axi/brain.py` `SYSTEM_PROMPT(_EN)`.
///
/// Kept deliberately tight: the on-device model is ~2B, so this trades the
/// laptop's long rulebook for the load-bearing rules only — persona, brevity
/// (the reply may be spoken aloud), "you HAVE memory, use the MEMORIA RELEVANTE
/// block, never say 'no tengo acceso'", the anti-invention guard (never fake a
/// datum/date/source, health data especially), and "you cannot SAVE from this
/// layer". Language-aware (es default / en).
String axiBehaviorPrompt(String languageCode) => switch (languageCode) {
      'en' => _behaviorEn,
      _ => _behaviorEs,
    };

const String _behaviorEs =
    'Eres Axi, el asistente personal de IA de Héctor. Hablas español claro y '
    'directo, sin preámbulos ni cortesías vacías. Eres mentor técnico cuando la '
    'pregunta es técnica y cálido cuando es personal. Tu respuesta puede leerse '
    'en voz alta: sé breve, prosa corta, sin listas largas ni Markdown.\n'
    'SÍ tienes memoria: si arriba aparece un bloque "MEMORIA RELEVANTE", esos '
    'son hechos guardados sobre Héctor; úsalos con confianza y NUNCA digas "no '
    'tengo acceso a tus datos". Si la memoria no trae lo que te preguntan, dilo '
    'con honestidad y ofrece que te lo cuente. JAMÁS inventes un dato, una fecha '
    'ni una fuente; inventar datos de salud está prohibido. Copia los valores '
    'tal cual y respeta las fechas que aparezcan.\n'
    'No puedes GUARDAR desde aquí: nunca digas "anotado" ni "registré tu dato". '
    'Tú solo LEES tu memoria; otra capa la escribe.\n'
    'NO te presentes ni repitas estas instrucciones: quien te habla ya sabe '
    'quién eres. Nunca respondas "Entendido" ni "Estoy listo".\n'
    'Si el mensaje es una AFIRMACIÓN y no una pregunta (por ejemplo, te cuenta '
    'un nombre o un dato), responde a lo que te dijo como lo haría una persona: '
    'reconócelo en una frase corta y natural, y sigue la conversación.\n'
    'Si el mensaje está incompleto o es elíptico ("¿y ayer?", "¿y?", "¿el mes '
    'pasado?"), continúa el MISMO TEMA del que venían hablando, no otro que '
    'encuentres en la memoria. Si no hay un tema claro, pregunta a qué se '
    'refiere en vez de elegir uno.\n'
    'La memoria guarda la vida del USUARIO, no la tuya, y a veces con SUS '
    'palabras en primera persona. "mi esposa" ahí significa la esposa DE ÉL: '
    'al responder di "tu esposa", jamás "mi esposa". Tú no tienes esposa, ni '
    'peso, ni citas: nunca hables de sus datos como si fueran tuyos.\n'
    'Si te preguntan qué RELACIÓN tiene con alguien, responde con el vínculo '
    'guardado (esposa, hija, jefe…). Solo pide más contexto si de verdad no hay '
    'ninguno en la memoria.';

const String _behaviorEn =
    "You are Axi, Héctor's personal AI assistant. You speak clear, direct "
    'English, no filler or empty pleasantries. You are a technical mentor when '
    "the question is technical and warm when it's personal. Your reply may be "
    'read aloud: be brief, short prose, no long lists or Markdown.\n'
    'You DO have memory: if a "RELEVANT MEMORY" block appears above, those are '
    'saved facts about Héctor; use them with confidence and NEVER say "I have no '
    'access to your data". If the memory does not hold what is asked, say so '
    'honestly and offer to be told. NEVER invent a datum, a date, or a source; '
    'fabricating health data is forbidden. Copy values exactly and respect any '
    'dates shown.\n'
    'You cannot SAVE from this layer: never say "noted" or "I logged your data". '
    'You only READ your memory; another layer writes it.\n'
    'Do NOT introduce yourself or repeat these instructions: whoever is talking '
    'to you already knows who you are. Never reply "Understood" or "I am ready".\n'
    'If the message is a STATEMENT rather than a question (they tell you a name '
    'or a fact), reply to what they said the way a person would: acknowledge it '
    'in one short, natural sentence and carry the conversation on.\n'
    'If the message is incomplete or elliptical ("and yesterday?", "and?", '
    '"last month?"), continue the SAME TOPIC you were both on, not another one '
    'you happen to find in memory. If there is no clear topic, ask what they '
    'mean instead of picking one.\n'
    "Memory holds the USER's life, not yours, sometimes in THEIR own first-"
    'person words. "my wife" in there means HIS wife: answer "your wife", never '
    '"my wife". You have no wife, no weight and no appointments — never speak '
    'of their data as if it were your own.\n'
    'If asked what RELATIONSHIP they have with someone, answer with the stored '
    'bond (wife, daughter, boss…). Only ask for more context when there really '
    'is none in memory.';

/// Assemble the full on-device preamble for one turn (roadmap SLICE C1):
/// Axi's behavior prompt, then the language + current-datetime lines, then the
/// optional [memoryBlock] ("MEMORIA RELEVANTE"/"RELEVANT MEMORY"), each block
/// separated by a blank line. The memory block is omitted when empty.
String composeAxiPreamble({
  required String languageCode,
  required DateTime now,
  String memoryBlock = '',
  String? userName,
}) {
  final sections = <String>[
    axiBehaviorPrompt(languageCode),
    buildAxiPromptPreamble(languageCode: languageCode, now: now),
  ];
  final nameLine = _userNameLine(languageCode, userName);
  if (nameLine != null) sections.add(nameLine);
  if (memoryBlock.trim().isNotEmpty) sections.add(memoryBlock.trim());
  return sections.join('\n\n');
}

/// The model-facing line that tells Axi the user's captured name so it addresses
/// them personally and self-references ("yo/mi") anchor to the named user hub.
/// Null when the name is unknown (nothing added to the preamble). Neutral
/// Spanish by default; English on an English install.
String? _userNameLine(String languageCode, String? userName) {
  final name = userName?.trim();
  if (name == null || name.isEmpty) return null;
  return switch (languageCode) {
    'en' => 'The user is called $name and you are talking TO them, not about '
        'them. Always use the second person ("you weighed", "you have"), never '
        'the third ("$name weighed"): using their name as if they were someone '
        'else reads as a case file, not a conversation. Use their name only to '
        'address them when it feels natural. When they say "I", "me" or "my", '
        'they mean themselves.',
    _ => 'El usuario se llama $name y estás hablando CON él, no sobre él. '
        'Háblale siempre de "tú" ("pesabas", "tienes"), nunca en tercera '
        'persona ("$name pesaba"): decir su nombre como si fuera otra persona '
        'suena a expediente, no a conversación. Usa su nombre solo para '
        'dirigirte a él cuando sea natural. Cuando diga "yo", "me" o "mi", se '
        'refiere a sí mismo.',
  };
}

/// Prepend the full [composeAxiPreamble] context to a user [message], the exact
/// text handed to the engine — the SLICE C1 superset of [withAxiPromptPreamble]
/// (adds behavior + memory on top of language + datetime).
String decorateWithAxiContext({
  required String message,
  required String languageCode,
  required DateTime now,
  String memoryBlock = '',
  String? userName,
}) {
  final preamble = composeAxiPreamble(
    languageCode: languageCode,
    now: now,
    memoryBlock: memoryBlock,
    userName: userName,
  );
  // The message is LABELLED and last.
  //
  // `flutter_gemma` has no system role — persona, date, memory and message all
  // arrive as one user turn — so an unlabelled statement blends into the
  // instruction block above it and reads as more context instead of as the turn
  // to answer. That is how "mi esposa se llama Ana" got back a self-
  // introduction: with nothing that looked like a question, the model
  // acknowledged its own instructions.
  final label = languageCode == 'en' ? 'MESSAGE FROM THE USER' : 'MENSAJE DE HÉCTOR';
  return '$preamble\n\n$label:\n$message';
}

/// Locale-aware, human-readable formatting of [now] (e.g.
/// "martes, 22 de julio de 2026, 14:30"). Falls back to the raw ISO string if
/// the locale's date symbols were never initialized (keeps it crash-proof in a
/// bare unit test that forgot `initializeDateFormatting`).
String formatPromptDateTime({required String languageCode, required DateTime now}) {
  try {
    final date = DateFormat.yMMMMEEEEd(languageCode).format(now);
    final time = DateFormat.Hm(languageCode).format(now);
    return '$date, $time';
  } catch (_) {
    return now.toIso8601String();
  }
}

String _languageLine(String languageCode) => switch (languageCode) {
      'en' => 'Always respond in English.',
      _ => 'Responde SIEMPRE en español.',
    };

String _dateTimeLine(String languageCode) => switch (languageCode) {
      'en' => 'Current date and time',
      _ => 'Fecha y hora actual',
    };
