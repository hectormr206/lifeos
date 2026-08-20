/// Cuándo lo que contestó el modelo no es una respuesta.
///
/// LO QUE PASÓ. Medido en el Pixel el 2026-08-20, tres turnos seguidos:
/// el usuario contaba un hecho y Axi le devolvía la misma frase con "mi"
/// cambiado por "tu"; al tercero, ante algo íntimo, contestó "¿Qué necesitas,
/// Héctor?". Un eco no es conversar, y una fórmula de recepcionista después de
/// que alguien te cuenta algo suyo es peor: además de no escuchar, cambia de
/// tema.
///
/// POR QUÉ ESTO ES CÓDIGO Y NO UNA REGLA MÁS EN EL PROMPT. El prompt ya pedía
/// "reconócelo en una frase corta y natural y sigue la conversación". Un modelo
/// de este tamaño no obedece esa clase de instrucción de forma fiable, y cada
/// regla nueva que se le añade afloja la anterior. Lo que sí es fiable es
/// mirar lo que devolvió y decidir aquí.
library;

/// Palabras que no aportan nada al comparar dos frases: si lo único que
/// distingue la respuesta del mensaje son estas, es la misma frase.
const Set<String> _noise = {
  'el', 'la', 'los', 'las', 'un', 'una', 'unos', 'unas',
  'de', 'del', 'en', 'a', 'al', 'y', 'o', 'que', 'se', 'es',
  'mi', 'mis', 'tu', 'tus', 'su', 'sus', 'me', 'te', 'le',
  'por', 'para', 'con', 'sin', 'lo',
};

List<String> _meaningfulWords(String text) {
  final cleaned = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^\wáéíóúüñ\s]', unicode: true), ' ');
  return [
    for (final word in cleaned.split(RegExp(r'\s+')))
      if (word.isNotEmpty && !_noise.contains(word)) word,
  ];
}

/// Si la respuesta es, en lo esencial, el mensaje devuelto.
///
/// Una PREGUNTA nunca cuenta como eco: "¿dónde nació mi esposa?" respondida
/// con "tu esposa nació en Cadereyta" es exactamente lo que debe hacer, y
/// confundir eso con un eco rompería la mitad útil del chat.
bool isEchoReply({required String userText, required String reply}) {
  if (userText.trim().contains('?') || userText.trim().contains('¿')) {
    return false;
  }
  final asked = _meaningfulWords(userText);
  final answered = _meaningfulWords(reply);
  // Con tres palabras o menos no hay frase que repetir: cualquier respuesta
  // que las use parecería un eco, y estaríamos cambiando respuestas buenas por
  // reconocimientos genéricos.
  if (asked.length < 4 || answered.isEmpty) return false;

  // Todo lo que dijo el usuario reaparece, y la respuesta no añade nada
  // sustancial: eso es el eco. Se permite alguna palabra nueva ("listo",
  // "anotado") porque el modelo suele adornar el eco con una.
  final reused = asked.where(answered.contains).length;
  final novel = answered.where((w) => !asked.contains(w)).length;
  return reused >= asked.length * 0.8 && novel <= 2;
}

/// Fórmulas de recepcionista: responden sin haber escuchado.
const List<String> _pleasantries = [
  'que necesitas',
  'en que puedo ayudar',
  'como puedo ayudar',
  'entendido',
  'estoy listo',
  'de acuerdo',
  'anotado',
  'perfecto',
];

bool isEmptyPleasantry(String reply) {
  final flat = reply
      .toLowerCase()
      .replaceAll(RegExp(r'[áàä]'), 'a')
      .replaceAll(RegExp(r'[éèë]'), 'e')
      .replaceAll(RegExp(r'[íìï]'), 'i')
      .replaceAll(RegExp(r'[óòö]'), 'o')
      .replaceAll(RegExp(r'[úùü]'), 'u')
      .replaceAll(RegExp(r'[^\w\s]', unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (flat.isEmpty) return true;
  // Sólo cuenta si la fórmula ES la respuesta, no si aparece dentro de una
  // frase larga que sí dice algo.
  final words = flat.split(' ').length;
  if (words > 8) return false;
  return _pleasantries.any(flat.contains);
}
