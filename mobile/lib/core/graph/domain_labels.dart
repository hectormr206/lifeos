// What a graph domain is CALLED when a person reads it.
//
// The graph stores English keys ('health', 'relationships') because the code
// is written in English. The user has never seen those words, and the screens
// that show them their own memories are the last place to start.
//
// Shared rather than per-screen: the 3D brain translated these and "Mi
// memoria" did not, so the same node read "Salud" in one screen and "health"
// in the next.
library;

const Map<String, String> _labels = {
  'health': 'Salud',
  'finance': 'Finanzas',
  'finances': 'Finanzas',
  'relationships': 'Relaciones',
  'exercise': 'Ejercicio',
  'calendar': 'Calendario',
  'spirituality': 'Espiritualidad',
  'learning': 'Aprendizaje',
  'lifeos-events': 'Eventos',
  'conversation': 'Conversación',
  'fact': 'Hecho',
  'person': 'Persona',
  'event': 'Evento',
  'personal': 'Personal',
};

/// The Spanish name of a domain, or the key itself when nobody has named it.
///
/// An unknown key comes back unchanged on purpose: a raw key looks odd, but a
/// guessed label on someone's own data is a small lie, and this app does not
/// tell those.
String domainLabel(String key) {
  if (key.isEmpty) return '';
  return _labels[key.toLowerCase()] ?? key;
}
