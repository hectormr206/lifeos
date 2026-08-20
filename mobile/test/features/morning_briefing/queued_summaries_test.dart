// Dos resúmenes en cola no se pisan.
//
// Reportado: "cuando le doy clic en Ver resumen completo y seguido en Ver
// resumen de comentarios, se procesa el primero y el otro se queda en cola;
// una vez que el segundo se procesa, el primero se borra".
//
// LA CAUSA es una foto vieja. Cada trabajo captura el artículo EN EL MOMENTO
// DE ENCOLARSE y, al terminar, escribe esa foto con su resultado encima:
//
//   1. Se encola A con la foto S0 (sin resumen).
//   2. Se encola B con la MISMA foto S0.
//   3. A termina y escribe S0 + resumen completo.  ✓
//   4. B termina y escribe S0 + resumen de comentarios — y S0 no tiene el
//      resumen completo, así que lo borra.  ✗
//
// El usuario lo dedujo solo: "esto puede pasar en todo lo que se vaya a cola".
// Tiene razón, y por eso la prueba mira la propiedad general — un trabajo que
// termina tarde no puede deshacer lo que otro escribió mientras tanto — y no
// sólo el par concreto que él encontró.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';

void main() {
  final article = BriefingArticle(
    title: 'Una noticia',
    url: 'https://ejemplo.com/n1',
    sourceName: 'BBC Mundo',
    publishedAt: DateTime.utc(2026, 8, 20, 6),
  );

  test('aplicar un cambio sobre la foto vieja pierde el otro', () {
    // Lo que pasaba: la demostración del bug, en una línea.
    final stale = article;
    final withFull = article.copyWith(fullSummary: 'el resumen completo');

    final overwritten = stale.copyWith(commentsSummary: 'los comentarios');

    expect(withFull.fullSummary, isNotNull);
    expect(overwritten.fullSummary, isNull,
        reason: 'así es como se borraba el primero');
  });

  test('aplicar sobre el artículo ACTUAL conserva los dos', () {
    // El arreglo: leer el vigente en el momento de escribir, no el de encolar.
    final current = article.copyWith(fullSummary: 'el resumen completo');

    final merged = current.copyWith(commentsSummary: 'los comentarios');

    expect(merged.fullSummary, 'el resumen completo');
    expect(merged.commentsSummary, 'los comentarios');
  });

  test('el orden inverso también conserva los dos', () {
    // Si el de comentarios termina primero, el completo no puede borrarlo.
    final current = article.copyWith(commentsSummary: 'los comentarios');

    final merged = current.copyWith(fullSummary: 'el resumen completo');

    expect(merged.commentsSummary, 'los comentarios');
    expect(merged.fullSummary, 'el resumen completo');
  });

  test('reemplazar un artículo no toca a los demás', () {
    final briefing = OnDeviceBriefing(
      generatedAt: DateTime.utc(2026, 8, 20, 6),
      articles: [
        article,
        BriefingArticle(
          title: 'Otra',
          url: 'https://ejemplo.com/n2',
          sourceName: 'BBC Mundo',
          publishedAt: DateTime.utc(2026, 8, 20, 6),
        ),
      ],
    );

    final updated = briefing.replaceArticle(
      article.key,
      article.copyWith(fullSummary: 'listo'),
    );

    expect(updated.articleForKey(article.key)!.fullSummary, 'listo');
    expect(updated.articles, hasLength(2));
  });
}
