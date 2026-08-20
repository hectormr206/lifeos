// Qué ajustes viajan entre dispositivos, y cuáles no.
//
// Pedido: "la configuración entre dispositivos, como el boletín y la hora en
// que el usuario decidió lanzarlo". Hoy las preferencias viven en
// shared_preferences, que es local por definición: el usuario pone el boletín
// a las 7:00 en la laptop y el teléfono sigue a las 8:00, sin decir nada.
//
// LA DISTINCIÓN QUE IMPORTA, y de la que sale todo lo demás:
//
//   * Una DECISIÓN sobre su vida viaja. "Quiero el boletín a las 7" es cierto
//     en todos sus aparatos, y tener que repetirla en cada uno es la clase de
//     trabajo que hace que la gente deje de configurar nada.
//
//   * Un HECHO sobre un aparato se queda. Qué modelo está descargado, si hay
//     micrófono, qué zona detectó el sistema: sincronizar eso rompe el
//     dispositivo que lo recibe, porque describe una máquina que no es la
//     suya.
//
// Confundir las dos es lo que convierte la sincronización de ajustes en una
// función que la gente apaga.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/settings/domain/synced_settings.dart';

void main() {
  group('qué viaja y qué no', () {
    test('las decisiones del usuario viajan', () {
      for (final key in const [
        'briefing.time',
        'briefing.auto',
        'briefing.sources',
        'digest.time',
        'digest.auto',
        'app.language',
        'app.theme',
        'voice.autoSpeak',
      ]) {
        expect(isSyncedSetting(key), isTrue, reason: '$key debería viajar');
      }
    });

    test('lo que describe al aparato se queda', () {
      for (final key in const [
        'model.installed',
        'model.path',
        'stt.modelInstalled',
        'device.nickname',
        'sync.enabled',
        'timezone.detected',
        'update.lastCheck',
      ]) {
        expect(isSyncedSetting(key), isFalse, reason: '$key NO debería viajar');
      }
    });

    test('una clave desconocida NO viaja', () {
      // Por defecto local: sincronizar algo que nadie pensó puede romper el
      // aparato que lo recibe, y el daño lo descubre el usuario.
      expect(isSyncedSetting('algo.que.nadie.penso'), isFalse);
    });

    test('sync.enabled jamás viaja', () {
      // Si viajara, apagar la sincronización en un aparato la apagaría en
      // todos — incluida la vía por la que llegó la orden.
      expect(isSyncedSetting('sync.enabled'), isFalse);
    });
  });

  group('quién gana cuando dos aparatos cambian lo mismo', () {
    test('gana el cambio más reciente', () {
      final winner = resolveSetting(
        mine: const SettingValue(value: '07:00', lamport: 5),
        theirs: const SettingValue(value: '08:00', lamport: 9),
      );

      expect(winner.value, '08:00');
    });

    test('un empate se resuelve igual en los dos aparatos', () {
      // Sin una regla determinista, cada aparato elegiría el suyo y quedarían
      // divergidos para siempre — el mismo error que ya costó una tarde en la
      // sincronización del grafo.
      const a = SettingValue(value: 'aaa', lamport: 7);
      const b = SettingValue(value: 'bbb', lamport: 7);

      expect(resolveSetting(mine: a, theirs: b).value,
          resolveSetting(mine: b, theirs: a).value);
    });

    test('lo que no existe localmente se acepta', () {
      final winner = resolveSetting(
        mine: null,
        theirs: const SettingValue(value: '07:00', lamport: 1),
      );

      expect(winner.value, '07:00');
    });

    test('lo que no llega no borra lo que hay', () {
      final winner = resolveSetting(
        mine: const SettingValue(value: '07:00', lamport: 1),
        theirs: null,
      );

      expect(winner.value, '07:00');
    });
  });
}
