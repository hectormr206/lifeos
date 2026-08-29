// Enviar una fuente nueva en el código NO se la da a nadie.
//
// El 2026-08-29 el usuario pidió más noticias de deportes, Linux e IA. Se
// midieron y eligieron seis fuentes vivas… y no le habrían llegado ninguna:
// `sources()` devuelve la lista GUARDADA del dispositivo, y `healBriefingSources`
// sólo cura URLs muertas y temas — nunca añade lo que se envió después. Habría
// tenido que darlas de alta a mano una por una, en cada aparato.
//
// La regla que fija esta prueba: una fuente de fábrica que NUNCA se le ha
// ofrecido a este dispositivo se añade; una que sí se le ofreció y ya no está
// es que el usuario la quitó, y eso se respeta.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/briefing_source.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('una fuente de fábrica nunca ofrecida se añade a la lista guardada', () {
    final guardadas = [
      const BriefingSource(url: 'https://feeds.bbci.co.uk/mundo/rss.xml', section: 'Mundo'),
    ];

    final resultado = withNewBuiltIns(
      guardadas,
      alreadyOffered: {briefingSourceKey('https://feeds.bbci.co.uk/mundo/rss.xml')},
    );

    expect(resultado.length, greaterThan(1));
    expect(
      resultado.map((s) => briefingSourceKey(s.url)),
      contains(briefingSourceKey('https://www.record.com.mx/rss')),
      reason: 'las fuentes nuevas de deportes tienen que llegar al dispositivo',
    );
  });

  test('una fuente que el usuario quitó NO vuelve sola', () {
    final guardadas = [
      const BriefingSource(url: 'https://feeds.bbci.co.uk/mundo/rss.xml', section: 'Mundo'),
    ];

    // Ya se le ofrecieron TODAS: que sólo quede una significa que borró el resto.
    final resultado = withNewBuiltIns(
      guardadas,
      alreadyOffered: {for (final s in defaultBriefingSources) briefingSourceKey(s.url)},
    );

    expect(
      resultado.map((s) => briefingSourceKey(s.url)),
      [briefingSourceKey('https://feeds.bbci.co.uk/mundo/rss.xml')],
      reason: 'resucitar lo que el usuario borró es peor que no añadir nada',
    );
  });

  test('lo que se añade conserva su tema, no cae en General', () {
    final resultado = withNewBuiltIns(
      const [BriefingSource(url: 'https://feeds.bbci.co.uk/mundo/rss.xml', section: 'Mundo')],
      alreadyOffered: const {},
    );

    final record = resultado.firstWhere(
      (s) => briefingSourceKey(s.url) == briefingSourceKey('https://www.record.com.mx/rss'),
    );
    expect(record.section, 'Deportes');
  });

  test('la línea base cubre exactamente lo que se envió antes de este mecanismo', () {
    // Si alguien añade una fuente de fábrica y olvida esto, la prueba de arriba
    // lo caza; esta explica por qué la base existe.
    for (final url in builtInsOfferedBefore) {
      expect(url, startsWith('https://'));
    }
    expect(builtInsOfferedBefore, hasLength(16));
  });
  _pruebaDeUnion();
}

// La prueba de unión: que `withNewBuiltIns` funcione no sirve de nada si
// `sources()` no lo llama. Esto es lo que de verdad llega al dispositivo.
void _pruebaDeUnion() {
  test('un dispositivo con su lista vieja recibe las fuentes nuevas al leer',
      () async {
    SharedPreferences.setMockInitialValues({
      SharedPrefsMorningBriefingPreferences.sourcesKey: [
        for (final url in builtInsOfferedBefore) 'Mundo|$url',
      ],
    });
    final prefs = SharedPrefsMorningBriefingPreferences();

    final leidas = await prefs.sources();

    expect(
      leidas.map((s) => briefingSourceKey(s.url)),
      contains(briefingSourceKey('https://the-decoder.com/feed/')),
      reason: 'la fuente nueva de IA tiene que llegar sin que él haga nada',
    );
    expect(leidas.length, builtInsOfferedBefore.length + 6);
  });

  test('leer dos veces no duplica ni vuelve a añadir', () async {
    SharedPreferences.setMockInitialValues({
      SharedPrefsMorningBriefingPreferences.sourcesKey: [
        for (final url in builtInsOfferedBefore) 'Mundo|$url',
      ],
    });
    final prefs = SharedPrefsMorningBriefingPreferences();

    final primera = await prefs.sources();
    // El usuario quita una de las nuevas: no puede resucitar en la lectura
    // siguiente, porque ya se le ofreció.
    await prefs.setSources([
      for (final s in primera)
        if (briefingSourceKey(s.url) !=
            briefingSourceKey('https://the-decoder.com/feed/'))
          s,
    ]);
    final segunda = await prefs.sources();

    expect(
      segunda.map((s) => briefingSourceKey(s.url)),
      isNot(contains(briefingSourceKey('https://the-decoder.com/feed/'))),
      reason: 'lo que quita el usuario se queda quitado',
    );
    expect(segunda.length, primera.length - 1);
  });
  _respetaLaCuracion();
}

// Una lista curada a mano es una decisión, no un descuido.
void _respetaLaCuracion() {
  test('una lista vacía a propósito se queda vacía', () {
    expect(withNewBuiltIns(const [], alreadyOffered: const {}), isEmpty);
  });

  test('una lista sólo con fuentes propias no recibe nada de fábrica', () {
    const mias = [
      BriefingSource(url: 'https://a.com/rss', section: 'Mundo'),
      BriefingSource(url: 'https://b.com/feed', section: 'Linux'),
    ];

    expect(withNewBuiltIns(mias, alreadyOffered: const {}), mias);
  });
}
