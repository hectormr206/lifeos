// Aplicar los ajustes que llegaron de otro dispositivo.
//
// Se llama al arrancar y después de cada sincronización que trajo filas — el
// mismo enganche que rearma los recordatorios y los cumpleaños, y por la misma
// razón: alguien que cambió la hora del boletín en la laptop no debería tener
// que abrir nada en el teléfono para que valga.
//
// LA DIRECCIÓN IMPORTA. Al guardar se escribe en los dos sitios (local, que es
// de donde la app lee, y el grafo, que es lo que viaja). Al arrancar se lee
// del grafo y se aplica encima de lo local. Un aparato que estuvo apagado una
// semana se pone al día solo.
library;

import '../../morning_briefing/domain/briefing_schedule.dart';
import '../../morning_briefing/domain/morning_briefing_preferences.dart';
import '../domain/settings_bridge.dart';
import 'synced_settings_store.dart';

/// Escribe el horario del boletín en los dos lados.
Future<void> saveBriefingSchedule({
  required BriefingSchedule schedule,
  required MorningBriefingPreferences preferences,
  required SyncedSettingsStore synced,
}) async {
  // Local primero: es de donde la app lee, y tiene que quedar aplicado aunque
  // el grafo no esté disponible en este arranque.
  await preferences.saveSchedule(schedule);
  await synced.put(
    'briefing.time',
    encodeScheduleSetting(
      enabled: schedule.enabled,
      hour: schedule.hour,
      minute: schedule.minute,
    ),
  );
}

/// Aplica lo que llegó de otro dispositivo, si llegó algo entendible.
///
/// Devuelve el horario resultante, o null cuando nada cambió — así el llamador
/// sabe si tiene que reprogramar las alarmas en vez de reprogramarlas siempre.
Future<BriefingSchedule?> applySyncedBriefingSchedule({
  required MorningBriefingPreferences preferences,
  required SyncedSettingsStore synced,
}) async {
  try {
    final raw = await synced.get('briefing.time');
    if (raw == null) return null;
    final decoded = decodeScheduleSetting(raw);
    // No se entiende: se deja lo que hay. Un valor corrupto no debe apagarle
    // el boletín a nadie.
    if (decoded == null) return null;

    final current = await preferences.schedule();
    if (current.enabled == decoded.enabled &&
        current.hour == decoded.hour &&
        current.minute == decoded.minute) {
      return null; // Ya estaba así.
    }

    final next = BriefingSchedule(
      enabled: decoded.enabled,
      hour: decoded.hour,
      minute: decoded.minute,
    );
    await preferences.saveSchedule(next);
    return next;
  } catch (_) {
    // Sin grafo se sigue con lo local: la app funciona igual, sólo que este
    // aparato no se entera del cambio hasta la próxima.
    return null;
  }
}
