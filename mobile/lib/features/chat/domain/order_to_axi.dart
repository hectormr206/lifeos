// Una ORDEN a Axi — "cuéntame un chiste", "haz una lista", "traduce esto".
//
// No es una pregunta ni algo que le pasó al usuario: describe una TAREA. Vive
// aparte porque dos capas muy distintas necesitan la misma lectura y ninguna
// puede permitirse una copia propia que se desincronice:
//
//  * la captura determinista, para no archivar un encargo como si fuera un
//    recuerdo ("Cuenta del 1 al 30 separados por comas" acabó en Finanzas);
//  * el sujeto de la conversación, porque un verbo en imperativo con mayúscula
//    inicial no es el nombre de nadie — y darlo por persona contamina TODOS los
//    turnos siguientes, que se reescriben con ese "nombre" delante.
//
// Barata a propósito: mira la PRIMERA palabra y nada más. Se consulta en cada
// turno, y una lectura cara aquí se paga en cada tecla.
library;

import '../../memory/domain/subject.dart' show foldAccents;

/// Verbos que, en imperativo y al principio de la frase, van dirigidos a Axi.
///
/// Sólo los que no dejan lugar a duda. Deliberadamente ausentes: "sigue"
/// ("sigue doliendo la espalda"), "pon", "abre", "cambia", "lee" — cada uno
/// abre una frase real bastante a menudo, y perder un registro es justo el
/// fallo que toda esta capa existe para evitar.
const Set<String> orderVerbs = <String>{
  // ES — sin acentos: "cuéntame" llega aquí como "cuentame".
  'cuenta', 'cuentame', 'cuentanos', 'dime', 'dinos', 'dame', 'danos',
  'escribe', 'escribeme', 'redacta', 'haz', 'hazme', 'hazlo', 'explica',
  'explicame', 'traduce', 'traduceme', 'resume', 'resumeme', 'calcula',
  'calculame', 'lista', 'listame', 'enumera', 'genera', 'crea', 'busca',
  'buscame', 'muestra', 'muestrame', 'ensename', 'repite', 'repiteme',
  'corrige', 'ayudame', 'define', 'describe', 'compara', 'imagina',
  'inventa', 'sugiere', 'sugiereme', 'recomienda', 'recomiendame',
  'deletrea', 'recuerdame', 'recordame',
  // EN
  'count', 'tell', 'give', 'write', 'explain', 'translate', 'summarize',
  'summarise', 'calculate', 'list', 'generate', 'create', 'search',
  'repeat', 'compare', 'imagine', 'spell', 'suggest', 'recommend',
  // 'define' / 'describe' ya están arriba: el imperativo es la misma palabra
  // en español y en inglés.
};

/// True cuando [text] empieza con un verbo de [orderVerbs].
bool looksLikeOrderToAxi(String text) {
  final t = text.trim();
  if (t.isEmpty) return false;
  return isOrderVerb(t.split(RegExp(r'\s+')).first);
}

/// True cuando [word] es, por sí sola, uno de esos imperativos.
bool isOrderVerb(String word) =>
    orderVerbs.contains(foldAccents(word.toLowerCase()));
