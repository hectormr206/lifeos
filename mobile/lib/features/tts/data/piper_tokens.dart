import 'dart:convert';

/// Raised when a `*.onnx.json` Piper voice config cannot be turned into a
/// sherpa-onnx token table.
class PiperTokensException implements Exception {
  PiperTokensException(this.message);
  final String message;
  @override
  String toString() => message;
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
