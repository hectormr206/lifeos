// Cambiar la hora del boletín en un aparato la cambia en todos.
//
// El puente entre las preferencias locales (que es donde la app las lee, y
// tiene que seguir siéndolo para que funcione sin grafo) y el grafo, que es lo
// único que viaja.
//
// La dirección importa: al GUARDAR se escribe en los dos sitios; al ARRANCAR
// se lee del grafo y se aplica encima de lo local. Así el aparato que estuvo
// apagado se pone al día solo, sin que nadie toque nada.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/settings/domain/settings_bridge.dart';

void main() {
  group('la hora del boletín, en el formato que viaja', () {
    test('se codifica de forma legible y estable', () {
      // Legible a propósito: este valor termina en un archivo de exportación
      // que una persona puede abrir.
      expect(encodeScheduleSetting(enabled: true, hour: 7, minute: 5),
          'on|07:05');
    });

    test('apagado se distingue de la hora', () {
      // Guardar sólo la hora perdería el "no lo generes solo", y el otro
      // aparato empezaría a generarlo.
      expect(encodeScheduleSetting(enabled: false, hour: 8, minute: 0),
          'off|08:00');
    });

    test('vuelve como salió', () {
      final decoded = decodeScheduleSetting('on|07:05')!;

      expect(decoded.enabled, isTrue);
      expect(decoded.hour, 7);
      expect(decoded.minute, 5);
    });

    test('lo que no se entiende no cambia nada', () {
      // Un valor corrupto o de una versión futura NO debe apagar el boletín
      // de alguien ni ponerlo a medianoche: null deja lo que ya había.
      for (final bad in const ['', 'on', 'on|', 'on|99:99', 'basura', '|07:00']) {
        expect(decodeScheduleSetting(bad), isNull, reason: bad);
      }
    });

    test('una hora imposible se rechaza, no se recorta', () {
      // Recortar 25:00 a 23:00 sería inventar una decisión que el usuario no
      // tomó.
      expect(decodeScheduleSetting('on|25:00'), isNull);
      expect(decodeScheduleSetting('on|07:60'), isNull);
    });

    test('medianoche es una hora válida', () {
      // 00:00 es falsy en varios lenguajes y es justo la que se pierde.
      final decoded = decodeScheduleSetting('on|00:00')!;

      expect(decoded.hour, 0);
      expect(decoded.minute, 0);
    });
  });
}
