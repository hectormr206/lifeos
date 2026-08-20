/// Cuándo volver a preguntar por el respaldo.
///
/// POR QUÉ EXISTE. LifeOS ya tiene respaldo cifrado manual, respaldo
/// automático al servidor por VPN y exportación. Nada de eso protege a nadie,
/// porque las tres cosas hay que activarlas ANTES, y nadie activa copias antes
/// de necesitarlas. El día que alguien pierda el teléfono, lo pierde todo — y
/// eso le va a pasar a alguien en cuanto esto se reparta en la familia.
///
/// Lo que falta no es mecanismo: es que la pregunta se haga, y que se vuelva a
/// hacer mientras la respuesta siga siendo "todavía no".
///
/// LA FORMA DE PREGUNTAR IMPORTA. Preguntar siempre igual de seguido es acoso,
/// y a un acoso la gente le aprende a decir que no sin leerlo. Dejar de
/// preguntar es abandonar a quien más falta le hace. Por eso el intervalo
/// crece cada vez que lo pospone, pero la pregunta nunca desaparece.
library;

class BackupState {
  const BackupState({
    required this.hasBackup,
    required this.postponedAt,
    required this.askedTimes,
    required this.entriesStored,
  });

  /// Si existe una copia de verdad: un archivo guardado, o el respaldo
  /// automático funcionando. No "la pantalla configurada".
  final bool hasBackup;

  /// La última vez que dijo "luego". Null si nunca se le preguntó.
  final DateTime? postponedAt;

  /// Cuántas veces lo ha pospuesto.
  final int askedTimes;

  /// Cuántas cosas hay guardadas. Respaldar una app vacía no protege a nadie,
  /// y gasta la única vez que la persona iba a leer el aviso con atención.
  final int entriesStored;
}

/// Ocho semanas: el techo de la espera.
///
/// Con tope, alguien que dijo "luego" veinte veces sigue recibiendo la
/// pregunta un par de veces al año. Sin tope, se quedaría sin respaldo y sin
/// nadie que se lo recordara nunca más.
const Duration kMaxBackupNagDelay = Duration(days: 56);

/// A partir de cuántas cosas guardadas vale la pena proteger lo que hay.
///
/// Veinte es "ya llevo un rato contándole mi vida", no "abrí la app y toqué
/// dos botones". Antes de eso, perder el teléfono cuesta cinco minutos de
/// volver a empezar, y el aviso sería sólo ruido.
const int kEntriesWorthProtecting = 20;

/// Cuánto esperar tras el enésimo "luego": una semana, y el doble cada vez.
Duration backupNagDelay(int askedTimes) {
  if (askedTimes <= 0) return Duration.zero;
  var days = 7;
  for (var i = 1; i < askedTimes && days < kMaxBackupNagDelay.inDays; i++) {
    days *= 2;
  }
  return days >= kMaxBackupNagDelay.inDays
      ? kMaxBackupNagDelay
      : Duration(days: days);
}

/// Si toca preguntar.
bool shouldAskForBackup(BackupState state, {required DateTime now}) {
  if (state.hasBackup) return false;
  // El primer día no hay nada que perder. La pregunta tiene sentido cuando ya
  // hay vida dentro — que es también cuando la persona entiende por qué se la
  // estamos haciendo.
  if (state.entriesStored < kEntriesWorthProtecting) return false;
  final last = state.postponedAt;
  if (last == null) return true;
  // Un reloj que va para atrás (zona horaria, hora corregida) no debe
  // convertirse en un aviso inmediato.
  final since = now.difference(last);
  if (since.isNegative) return false;
  return since >= backupNagDelay(state.askedTimes);
}
