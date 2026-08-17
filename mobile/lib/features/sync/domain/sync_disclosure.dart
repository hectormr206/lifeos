// What the relay can see, written for the person using the app.
//
// This is not legal boilerplate. It is the honest list, in the settings screen,
// in plain Spanish, because the whole promise of LifeOS is that your life does
// not live in someone else's cloud being mined — and a promise that hides its
// own exceptions is worth nothing.
//
// The list is derived from what `relay/app/store.py` actually persists, and the
// test pins them together: adding a column to the relay without adding it here
// fails, so the disclosure cannot quietly fall behind the code.
library;

/// One thing the relay unavoidably observes, and why it cannot be avoided.
class RelayObservation {
  const RelayObservation({required this.what, required this.why});

  /// Stated as the user would see it, not as a schema field.
  final String what;

  /// Why it is unavoidable. A disclosure without this reads as an apology; the
  /// point is that these are consequences of routing, not choices we made.
  final String why;
}

/// EXACTLY what the relay stores or can infer. Nothing else.
const List<RelayObservation> kRelayCanSee = [
  RelayObservation(
    what: 'El identificador aleatorio de cada buzón',
    why: 'Es la dirección: sin ella no sabría a qué dispositivo entregar el '
        'sobre. No lleva tu nombre ni el del aparato.',
  ),
  RelayObservation(
    what: 'Una llave pública por buzón, distinta en cada uno',
    why: 'Con ella comprueba que quien deposita tiene derecho a hacerlo. Como '
        'es distinta en cada buzón, no puede agrupar tus dispositivos.',
  ),
  RelayObservation(
    what: 'El tamaño de cada sobre y cuándo pasó',
    why: 'Mover bytes obliga a contarlos. De ahí se puede deducir cuántos '
        'dispositivos tienes y a qué horas los usas.',
  ),
  RelayObservation(
    what: 'La dirección IP desde la que te conectas',
    why: 'Es inherente a cualquier conexión de internet.',
  ),
];

/// What the relay CANNOT see, stated with the same weight.
///
/// A disclosure that only lists the bad news is as misleading as one that hides
/// it: the reason the list above is acceptable is precisely this list.
const List<String> kRelayCannotSee = [
  'El contenido de tus notas, conversaciones o registros — viaja cifrado y la '
      'llave nunca sale de tus dispositivos.',
  'Tu frase de recuperación, ni nada derivado de ella.',
  'Tu nombre, tu correo, ni el nombre que le pusiste a cada dispositivo.',
];

/// How long anything survives there.
const String kRelayRetention =
    'Un sobre se borra en cuanto tu otro dispositivo lo recoge. Si no lo '
    'recoge, se borra solo a los 30 días. El registro del buzón caduca también '
    'a los 30 días sin uso: si dejas de sincronizar, no queda nada tuyo en el '
    'servidor.';
