// Una fuente, una vez.
//
// Reportado: "en mi Pixel me creó 2 noticias de BBC Mundo". Dos entradas con
// la misma URL producen dos cosechas, dos grupos con el mismo nombre y las
// mismas noticias repetidas — y el usuario no tiene forma de saber cuál
// sobra.
//
// La causa puede ser una lista guardada con la URL repetida (por ejemplo la
// misma fuente bajo dos secciones tras el cambio de formato). Sea cual sea el
// origen, la defensa correcta es la misma y va en los DOS extremos: al leer la
// lista y al armar el boletín. Un duplicado que entró ayer no se arregla solo.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_source.dart';

void main() {
  group('la lista de fuentes', () {
    test('la misma URL dos veces se queda en una', () {
      final unique = dedupeBriefingSources(const [
        BriefingSource(url: 'https://feeds.bbci.co.uk/mundo/rss.xml', section: 'Mundo'),
        BriefingSource(url: 'https://feeds.bbci.co.uk/mundo/rss.xml', section: 'Mundo'),
      ]);

      expect(unique, hasLength(1));
    });

    test('la misma URL en dos secciones sigue siendo una fuente', () {
      // Descargarla dos veces gasta el doble y repite las noticias; la
      // sección es dónde se lee, no qué se descarga.
      final unique = dedupeBriefingSources(const [
        BriefingSource(url: 'https://a.com/rss', section: 'Mundo'),
        BriefingSource(url: 'https://a.com/rss', section: 'Linux'),
      ]);

      expect(unique, hasLength(1));
      expect(unique.first.section, 'Mundo', reason: 'gana la primera');
    });

    test('una barra final no la vuelve otra fuente', () {
      // "https://a.com/rss" y "https://a.com/rss/" son el mismo feed, y quien
      // las pega a mano acaba con las dos.
      final unique = dedupeBriefingSources(const [
        BriefingSource(url: 'https://a.com/rss', section: 'Mundo'),
        BriefingSource(url: 'https://a.com/rss/', section: 'Mundo'),
      ]);

      expect(unique, hasLength(1));
    });

    test('mayúsculas en el dominio tampoco', () {
      final unique = dedupeBriefingSources(const [
        BriefingSource(url: 'https://A.com/rss', section: 'Mundo'),
        BriefingSource(url: 'https://a.com/rss', section: 'Mundo'),
      ]);

      expect(unique, hasLength(1));
    });

    test('la RUTA sí distingue: no todo lo del mismo dominio es lo mismo', () {
      // BBC Mundo y BBC Ciencia viven en el mismo host y son fuentes
      // distintas; pasarse de listo aquí borraría una que el usuario quiere.
      final unique = dedupeBriefingSources(const [
        BriefingSource(url: 'https://feeds.bbci.co.uk/mundo/rss.xml', section: 'Mundo'),
        BriefingSource(
            url: 'https://feeds.bbci.co.uk/mundo/ciencia_tecnologia/rss.xml',
            section: 'Ciencia y salud'),
      ]);

      expect(unique, hasLength(2));
    });

    test('el orden se conserva', () {
      final unique = dedupeBriefingSources(const [
        BriefingSource(url: 'https://b.com/rss', section: 'Mundo'),
        BriefingSource(url: 'https://a.com/rss', section: 'Mundo'),
      ]);

      expect(unique.first.url, 'https://b.com/rss');
    });

    test('una lista sin duplicados no cambia', () {
      const list = [
        BriefingSource(url: 'https://a.com/rss', section: 'Mundo'),
        BriefingSource(url: 'https://b.com/rss', section: 'Linux'),
      ];

      expect(dedupeBriefingSources(list), hasLength(2));
    });
  });
}
