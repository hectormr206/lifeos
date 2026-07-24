import 'dart:convert';

import '../domain/piper_speech_synthesizer.dart';

/// Raised when a `*.onnx.json` Piper voice config cannot be turned into a
/// sherpa-onnx token table.
class PiperTokensException implements Exception {
  PiperTokensException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Throws [UnsupportedVoiceException] when [configJson] describes a voice the
/// on-device sherpa-onnx Piper engine cannot safely synthesize — otherwise
/// returns normally.
///
/// sherpa-onnx crashes NATIVELY (an uncatchable FFI abort that kills the whole
/// app) for two config shapes, so we reject them here — BEFORE handing the
/// model to the engine — with a catchable Dart exception:
///  * `phoneme_type` is absent or not "espeak": only espeak phonemization is
///    wired into the build; any other type (e.g. "text") aborts.
///  * multi-speaker (`num_speakers > 1`): the engine needs a speaker id per
///    utterance that we never pass, so it aborts.
///
/// Cheap and pure: it parses the same JSON the token table is derived from. A
/// config that is not valid JSON is treated as unsupported (it could not be
/// synthesized anyway).
void assertPiperVoiceCompatible(String configJson) {
  Map<String, dynamic> config;
  try {
    config = jsonDecode(configJson) as Map<String, dynamic>;
  } catch (_) {
    throw UnsupportedVoiceException(
      'La configuración de la voz no es válida para este dispositivo.',
    );
  }

  // phoneme_type MUST be "espeak" (Piper espeak voices nest it under
  // `phoneme_type`; some export it at the top level). Anything else — or a
  // missing value — crashes the engine.
  final phonemeType = config['phoneme_type'];
  if (phonemeType != 'espeak') {
    throw UnsupportedVoiceException(
      'Esta voz usa un fonemizador no compatible con este dispositivo.',
    );
  }

  // Multi-speaker voices (num_speakers > 1) need a speaker id we never pass.
  final numSpeakers = config['num_speakers'];
  if (numSpeakers is num && numSpeakers > 1) {
    throw UnsupportedVoiceException(
      'Esta voz tiene varios hablantes y no es compatible con este dispositivo.',
    );
  }
}

/// Derives the sherpa-onnx `tokens.txt` content from a Piper voice's
/// `*.onnx.json` config — the exact same table sherpa-onnx's piper conversion
/// script writes: one `<symbol> <id>` line per `phoneme_id_map` entry (first
/// id when a symbol maps to several).
///
/// Pure function so it is unit-testable; the downloader gateway writes the
/// result next to the model after each voice download, which keeps the hosted
/// file set to just `.onnx` + `.onnx.json`.
String piperTokensFromConfigJson(String configJson) {
  Map<String, dynamic> config;
  try {
    config = jsonDecode(configJson) as Map<String, dynamic>;
  } catch (e) {
    throw PiperTokensException('La configuración de la voz no es JSON válido: $e');
  }
  final map = config['phoneme_id_map'];
  if (map is! Map<String, dynamic> || map.isEmpty) {
    throw PiperTokensException('La configuración de la voz no trae phoneme_id_map.');
  }
  final buffer = StringBuffer();
  for (final entry in map.entries) {
    final ids = entry.value;
    if (ids is! List || ids.isEmpty || ids.first is! int) {
      throw PiperTokensException('Entrada inválida en phoneme_id_map: "${entry.key}".');
    }
    buffer.write(entry.key);
    buffer.write(' ');
    buffer.write(ids.first);
    buffer.write('\n');
  }
  return buffer.toString();
}
