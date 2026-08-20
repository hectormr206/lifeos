/// Lo que Axi contesta cuando le cuentas algo — en vez del eco.
///
/// Tiene que hacer dos cosas a la vez: dejar claro que lo escuchó, y dar pie a
/// seguir hablando. Y no puede inventar nada, ni para sonar más natural: puede
/// PREGUNTAR, nunca afirmar algo que nadie dijo. Preguntar es seguro; afirmar
/// es de donde salen los datos falsos.
///
/// Determinista a propósito: el mismo hecho recibe siempre la misma respuesta.
/// Sin eso, ninguna prueba de esto probaría nada — y una respuesta que cambia
/// sola entre dos ejecuciones es imposible de reproducir cuando falla.
library;

/// Lo que se cuenta en voz baja. Aquí no se pregunta: preguntar convierte una
/// confidencia en un formulario, y es la forma más rápida de que alguien deje
/// de contarte cosas.
final RegExp _intimate = RegExp(
  r'\b(hicimos el amor|acostamos|sex|íntim|intim|desnud|primera vez)',
  caseSensitive: false,
);

final RegExp _hasDate = RegExp(
  r'\b(\d{1,2} de \w+|\d{4}|enero|febrero|marzo|abril|mayo|junio|julio|'
  r'agosto|septiembre|octubre|noviembre|diciembre)\b',
  caseSensitive: false,
);

final RegExp _hasPlace = RegExp(
  r'\b(en|de) [A-ZÁÉÍÓÚÑ][\wáéíóúñ]+',
);

final RegExp _hasNumber = RegExp(r'\d+\s*(kilos?|kg|años?|\d+/\d+)');

/// Respuestas por tipo de dato. Varias por tipo porque contestar siempre igual
/// es otra forma de no escuchar.
const Map<String, List<String>> _byKind = {
  'fecha': [
    'Me quedo con esa fecha. ¿La celebran cada año?',
    'Guardada esa fecha. ¿Cómo la pasan normalmente?',
    'Ya la tengo. ¿Qué recuerdas de ese día?',
  ],
  'lugar': [
    'Ya lo tengo. ¿Siguen teniendo familia por allá?',
    'Guardado. ¿Van seguido para allá?',
    'Me lo apunto. ¿Qué tal se vive por ahí?',
  ],
  'numero': [
    'Ya quedó registrado. ¿Cómo te sentiste?',
    'Lo tengo. ¿Lo mides seguido?',
  ],
  'general': [
    'Ya lo tengo guardado. ¿Qué más me cuentas de eso?',
    'Me lo quedo. Sigue contándome.',
    'Guardado. ¿Y cómo va eso ahora?',
  ],
};

/// Para lo íntimo: se reconoce, y ahí se para.
const List<String> _intimateReplies = [
  'Gracias por contármelo. Lo guardo con el mismo cuidado que lo demás.',
  'Queda guardado, y sólo aquí.',
];

String _kindOf(String text) {
  if (_hasNumber.hasMatch(text)) return 'numero';
  if (_hasDate.hasMatch(text)) return 'fecha';
  if (_hasPlace.hasMatch(text)) return 'lugar';
  return 'general';
}

/// Suma estable de los caracteres: elige variante sin `Random`, que haría la
/// respuesta irreproducible.
int _stableIndex(String text, int options) {
  var sum = 0;
  for (final unit in text.codeUnits) {
    sum = (sum + unit) % 100003;
  }
  return sum % options;
}

/// La respuesta.
String acknowledgeStatement(String userText) {
  final text = userText.trim();
  if (_intimate.hasMatch(text)) {
    return _intimateReplies[_stableIndex(text, _intimateReplies.length)];
  }
  final options = _byKind[_kindOf(text)]!;
  return options[_stableIndex(text, options.length)];
}
