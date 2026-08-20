// El buscador que LifeOS trae puesto.
//
// Axi buscaba por DuckDuckGo. Medido desde el VPS el 2026-08-19 y otra vez el
// 2026-08-20: DuckDuckGo y Startpage responden CAPTCHA a quien consulta desde
// un centro de datos, y con el tiempo también a una casa que pregunta seguido.
// Depender de eso es tener búsqueda hasta el día que se apaga sin avisar.
//
// Ahora la app trae compilada la dirección del SearXNG propio y su llave. La
// llave va compilada y no en las preferencias a propósito: nadie tiene que
// pegarla, y no aparece en ninguna pantalla desde la que pueda filtrarse.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/web_search/domain/bundled_search_instance.dart';

void main() {
  group('la instancia que viene con la app', () {
    test('sin compilar nada, no hay instancia', () {
      // Un checkout no lleva el servidor de nadie dentro, igual que el
      // instalador de Linux no lleva una URL horneada.
      expect(
        const BundledSearchInstance(baseUrl: '', accessKey: '').isConfigured,
        isFalse,
      );
    });

    test('una dirección sin llave NO cuenta como configurada', () {
      // Mandar consultas a una puerta que va a responder 403 no es "buscar":
      // es fallar en silencio en cada pregunta que haga el usuario.
      expect(
        const BundledSearchInstance(baseUrl: 'https://s.example', accessKey: '')
            .isConfigured,
        isFalse,
      );
    });

    test('una llave sin dirección tampoco', () {
      expect(
        const BundledSearchInstance(baseUrl: '', accessKey: 'abc').isConfigured,
        isFalse,
      );
    });

    test('con las dos cosas, sí', () {
      expect(
        const BundledSearchInstance(
          baseUrl: 'https://search.example',
          accessKey: 'abc',
        ).isConfigured,
        isTrue,
      );
    });

    test('los espacios de más no la dan por buena', () {
      // Un --dart-define vacío que llega como " " haría creer a la app que
      // tiene buscador, y cada búsqueda moriría contra un host inexistente.
      expect(
        const BundledSearchInstance(baseUrl: '  ', accessKey: '  ').isConfigured,
        isFalse,
      );
    });
  });
}
