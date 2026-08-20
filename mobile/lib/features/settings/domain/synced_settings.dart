// Qué ajustes viajan entre los dispositivos del usuario.
//
// Las preferencias vivían sólo en shared_preferences, que es local por
// definición: alguien ponía el boletín a las 7:00 en la laptop y el teléfono
// seguía a las 8:00 sin decir nada.
//
// LA DISTINCIÓN DE LA QUE SALE TODO:
//
//   * Una DECISIÓN sobre su vida viaja. "Quiero el boletín a las 7" es cierto
//     en todos sus aparatos, y repetirlo en cada uno es la clase de trabajo
//     que hace que la gente deje de configurar nada.
//
//   * Un HECHO sobre un aparato se queda. Qué modelo está descargado, si hay
//     micrófono, qué zona detectó el sistema: sincronizar eso rompe el
//     dispositivo que lo recibe, porque describe una máquina que no es la
//     suya.
//
// La lista es explícita y cerrada. Lo desconocido NO viaja: sincronizar algo
// que nadie pensó puede romper el aparato que lo recibe, y el daño lo
// descubre el usuario.
library;

/// Ajustes que son decisiones del usuario y valen en todos sus aparatos.
const Set<String> kSyncedSettingKeys = {
  // El boletín: la hora que eligió, si se genera solo, y de dónde lee.
  'briefing.time',
  'briefing.auto',
  'briefing.sources',
  // El resumen del día, por lo mismo.
  'digest.time',
  'digest.auto',
  // Cómo quiere que le hable la app.
  'app.language',
  'app.theme',
  'voice.autoSpeak',
  'voice.selected',
  // La zona que ELIGIÓ a mano. La detectada automáticamente no: describe
  // dónde está cada aparato, que puede ser otro país.
  'timezone.override',
};

/// True cuando [key] debe viajar entre dispositivos.
bool isSyncedSetting(String key) => kSyncedSettingKeys.contains(key);

/// Un ajuste, con el reloj lógico que ya usa la sincronización del grafo.
class SettingValue {
  const SettingValue({required this.value, required this.lamport});

  final String value;

  /// El mismo reloj lógico de los nodos: reutilizarlo significa que el orden
  /// de los cambios es el mismo que el del resto de la sincronización, en vez
  /// de inventar una segunda noción de "más reciente" que podría contradecirla.
  final int lamport;
}

/// Quién gana cuando dos aparatos cambiaron el mismo ajuste.
///
/// El más reciente. Un EMPATE se rompe por el valor, de forma determinista:
/// sin eso, cada aparato elegiría el suyo y quedarían divergidos para siempre
/// — que es exactamente el error que ya costó una tarde en la sincronización
/// del grafo.
SettingValue resolveSetting({
  required SettingValue? mine,
  required SettingValue? theirs,
}) {
  if (mine == null) return theirs!;
  if (theirs == null) return mine;
  if (theirs.lamport != mine.lamport) {
    return theirs.lamport > mine.lamport ? theirs : mine;
  }
  return theirs.value.compareTo(mine.value) > 0 ? theirs : mine;
}
