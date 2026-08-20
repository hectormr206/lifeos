/// Qué merece ser un nodo del Cerebro.
///
/// LO QUE PASÓ. Visto el 2026-08-20 entre 41 nodos: "la otra persona", "Axi",
/// "esposa_nació", "noviazgo", "Casamiento", "Lugar del casamiento". Ninguno
/// dice nada de la vida de nadie — una referencia sin identidad, el propio
/// asistente, el nombre interno de un campo y tres etiquetas sueltas — y el
/// grafo se llena de ruido hasta que lo que sí importa se pierde dentro.
///
/// POR QUÉ ES CÓDIGO. Los nombra el modelo, y el prompt ya pedía "entidades
/// NOMBRADAS y concretas". No lo cumple, y una regla más en el prompt afloja
/// las que ya están.
///
/// EL CRITERIO. Una entidad merece existir si se puede VOLVER a ella: un
/// nombre propio, un vínculo, una condición. Lo que no se puede señalar dos
/// veces no es una entidad, es una palabra que pasaba por ahí.
library;

/// Referencias que no señalan a nadie.
const Set<String> _anonymous = {
  'la otra persona',
  'otra persona',
  'esa persona',
  'esta persona',
  'una persona',
  'la persona',
  'alguien',
  'alguno',
  'nadie',
  'el otro',
  'la otra',
  'ellos',
  'ella',
  'el',
  'usuario',
  'yo',
};

/// Quien pregunta no es parte de la vida de quien contesta.
const Set<String> _ourselves = {'axi', 'lifeos', 'asistente'};

/// Vínculos que valen como identidad mientras no haya un nombre: tirarlos
/// perdería la relación entera, que suele ser el dato más útil del turno.
const Set<String> _bonds = {
  'esposa', 'esposo', 'mujer', 'marido', 'pareja', 'novia', 'novio',
  'madre', 'padre', 'mamá', 'papá', 'hijo', 'hija', 'hermano', 'hermana',
  'abuelo', 'abuela', 'tío', 'tía', 'primo', 'prima', 'sobrino', 'sobrina',
  'suegro', 'suegra', 'cuñado', 'cuñada', 'jefe', 'jefa', 'amigo', 'amiga',
  'doctor', 'doctora', 'médico', 'colega', 'vecino', 'vecina', 'nieto',
  'nieta', 'yerno', 'nuera', 'compadre', 'comadre',
};

/// Tipos donde la minúscula es lo normal y no significa vaguedad.
const Set<String> _lowercaseKinds = {'condition', 'medication', 'thing', 'product'};

final RegExp _fieldName = RegExp(r'^[\wÀ-ɏ]+_[\wÀ-ɏ]+$');
final RegExp _hasProperNoun = RegExp(r'\b[A-ZÁÉÍÓÚÑ][\wáéíóúñ]{2,}');
final RegExp _hasNumberOrYear = RegExp(r'\d');

/// Quita el posesivo para poder reconocer el vínculo debajo.
String _core(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'^(mi|mis|su|sus|tu|tus|el|la|los|las)\s+'), '')
    .trim();

/// Todo menos la primera palabra, donde la mayúscula no significa nada.
String _afterFirstWord(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  return parts.length <= 1 ? '' : parts.sublist(1).join(' ');
}

bool isMeaningfulEntity({required String name, required String kind}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return false;
  // Sin una sola letra no hay nada que nombrar.
  if (!RegExp(r'[\wÀ-ɏ]').hasMatch(trimmed)) return false;
  // "esposa_nació": una clave interna que se coló como si fuera una cosa.
  if (_fieldName.hasMatch(trimmed)) return false;

  final lower = trimmed.toLowerCase();
  if (_ourselves.contains(lower)) return false;

  final core = _core(trimmed);
  if (_anonymous.contains(lower) || _anonymous.contains(core)) return false;
  if (_bonds.contains(core)) return true;

  if (_lowercaseKinds.contains(kind)) return true;

  // Un EVENTO sin cuándo ni quién no existe: "Casamiento" y "Lugar del
  // casamiento" no dicen de qué boda hablan, y nadie puede volver a ellos a
  // buscar nada. La mayúscula inicial no cuenta como nombre propio — toda
  // frase empieza en mayúscula.
  if (kind == 'event') {
    return _hasNumberOrYear.hasMatch(trimmed) ||
        _hasProperNoun.hasMatch(_afterFirstWord(trimmed));
  }

  // Para personas, lugares y organizaciones basta un nombre propio: "Querétaro"
  // señala un sitio concreto aunque sea una sola palabra.
  return _hasProperNoun.hasMatch(trimmed) || _hasNumberOrYear.hasMatch(trimmed);
}
