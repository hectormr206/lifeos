// Una fuente muerta no se arregla cambiando la lista por defecto.
//
// Medido el 2026-08-24: el feed de portada de El País que enviamos devuelve
// noticias de FEBRERO DE 2020, Genbeta lleva parada desde diciembre de 2025 y
// el feed de la OMS desde febrero de 2026. Como las fuentes se guardan en el
// teléfono la primera vez, editar `_shipped` no llega a nadie que ya abrió la
// app: hay que curar la lista guardada al leerla.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_source.dart';

void main() {
  group('healBriefingSources', () {
    test('cambia el feed roto de El País por el que sí publica hoy', () {
      final healed = healBriefingSources([
        const BriefingSource(
          url: 'https://elpais.com/rss/elpais/portada.xml',
          section: 'Mundo',
        ),
      ]);

      expect(healed.single.url, contains('feeds.elpais.com'));
      expect(
        healed.single.section,
        'Mundo',
        reason: 'la sección que el usuario eligió no se toca',
      );
    });

    test('quita las fuentes muertas que no tienen recambio', () {
      final healed = healBriefingSources([
        const BriefingSource(
          url: 'https://www.genbeta.com/index.xml',
          section: 'Tecnología',
        ),
        const BriefingSource(
          url: 'https://www.xataka.com/index.xml',
          section: 'Tecnología',
        ),
      ]);

      expect(healed.map((s) => s.url), ['https://www.xataka.com/index.xml']);
    });

    test('no toca una fuente que el usuario agregó por su cuenta', () {
      const mine = BriefingSource(
        url: 'https://ejemplo.com/feed',
        section: 'Mío',
      );
      expect(healBriefingSources([mine]).single.url, mine.url);
    });

    test('respeta que el usuario la haya apagado', () {
      final healed = healBriefingSources([
        const BriefingSource(
          url: 'https://elpais.com/rss/elpais/portada.xml',
          section: 'Mundo',
          enabled: false,
        ),
      ]);
      expect(healed.single.enabled, isFalse);
    });

    test('curar dos veces no cambia nada más (idempotente)', () {
      final once = healBriefingSources([
        const BriefingSource(
          url: 'https://elpais.com/rss/elpais/portada.xml',
          section: 'Mundo',
        ),
      ]);
      final twice = healBriefingSources(once);
      expect(twice.map((s) => s.url), once.map((s) => s.url));
    });

    test('si el recambio ya estaba en la lista no queda duplicado', () {
      final healed = healBriefingSources([
        const BriefingSource(
          url: 'https://elpais.com/rss/elpais/portada.xml',
          section: 'Mundo',
        ),
        const BriefingSource(
          url: 'https://feeds.elpais.com/mrss-s/pages/ep/site/elpais.com/portada',
          section: 'Mundo',
        ),
      ]);
      expect(healed, hasLength(1));
    });
  });

  test('la lista por defecto ya no envía ninguna fuente muerta', () {
    expect(
      healBriefingSources(defaultBriefingSources).length,
      defaultBriefingSources.length,
      reason: 'lo que enviamos debe estar ya curado',
    );
  });
}
