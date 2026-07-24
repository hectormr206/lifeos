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
    'Tú solo LEES tu memoria; otra capa la escribe.';

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
    'You only READ your memory; another layer writes it.';

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
    'en' => 'The user\'s name is $name. Address them by name when it feels '
        'natural. When the user says "I", "me" or "my", they mean $name.',
    _ => 'El usuario se llama $name. Dirígete a él por su nombre cuando sea '
        'natural. Cuando el usuario diga "yo", "me" o "mi", se refiere a $name.',
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
}) =>
    '${composeAxiPreamble(languageCode: languageCode, now: now, memoryBlock: memoryBlock, userName: userName)}\n\n$message';

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
