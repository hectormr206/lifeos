// Cómo viaja un horario entre dispositivos.
//
// El puente entre las preferencias locales — que es donde la app las lee, y
// tiene que seguir siéndolo para que funcione sin grafo — y el grafo, que es
// lo único que viaja.
//
// El formato es legible a propósito: este valor termina en el archivo de
// exportación que una persona puede abrir, y "on|07:05" se entiende sin
// documentación.
library;

/// Un horario tal como viaja.
typedef ScheduleSetting = ({bool enabled, int hour, int minute});

String _two(int n) => n.toString().padLeft(2, '0');

/// "on|07:05" — el interruptor Y la hora.
///
/// Los dos juntos: guardar sólo la hora perdería el "no lo generes solo", y el
/// otro aparato empezaría a generarlo.
String encodeScheduleSetting({
  required bool enabled,
  required int hour,
  required int minute,
}) =>
    '${enabled ? 'on' : 'off'}|${_two(hour)}:${_two(minute)}';

/// Lo que dice el ajuste, o null cuando no se entiende.
///
/// Null es la respuesta segura: un valor corrupto, o de una versión futura,
/// NO debe apagar el boletín de alguien ni ponerlo a medianoche. El llamador
/// se queda con lo que ya tenía.
ScheduleSetting? decodeScheduleSetting(String raw) {
  final match = RegExp(r'^(on|off)\|(\d{2}):(\d{2})$').firstMatch(raw.trim());
  if (match == null) return null;
  final hour = int.parse(match.group(2)!);
  final minute = int.parse(match.group(3)!);
  // Rechazada, no recortada: recortar 25:00 a 23:00 sería inventar una
  // decisión que el usuario no tomó.
  if (hour > 23 || minute > 59) return null;
  return (enabled: match.group(1) == 'on', hour: hour, minute: minute);
}
