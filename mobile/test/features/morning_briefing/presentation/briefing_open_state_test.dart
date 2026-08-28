// Lo que el lector reporto el 2026-08-27: "las secciones no se quedan abiertas
// cuando bajo o subo, se cierran", y "cuando le doy abrir resumen se abre pero
// de inmediato se cierra y me manda al final de las noticias".
//
// Ambos sintomas son la MISMA causa: lo que esta abierto vivia en el State de
// un widget dentro de una lista perezosa. Al salir de pantalla el elemento se
// destruye y su State con el; al volver se reconstruye cerrado, el alto total
// de la lista se encoge y el scroll se recorta hasta el final.
//
// Estas pruebas fijan la conducta observable: lo que el lector abrio sigue
// abierto, y abrirlo no lo mueve de sitio.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_providers.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_screen.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/locale_providers.dart';
import 'package:lifeos/core/clock/clock.dart';

import '../../local_model/support/fake_local_llm_engine.dart';
import '../support/fakes.dart';

class _FixedClock implements Clock {
  const _FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime now() => _now;
}

/// Un boletin ALTO a proposito: varias secciones con varias noticias cada una,
/// para que al desplegar una seccion las de abajo salgan de la ventana y el
/// framework las recicle — que es justo la condicion del fallo.
OnDeviceBriefing _tallBriefing() {
  final articles = <BriefingArticle>[];
  for (final section in ['Mundo', 'Tecnología', 'Ciencia', 'Deportes']) {
    for (var i = 1; i <= 6; i++) {
      articles.add(
        BriefingArticle(
          sourceName: 'Fuente $section',
          section: section,
          title: '$section noticia $i',
          url: 'https://ejemplo.com/${section.toLowerCase()}/$i',
          description: 'Detalle de $section noticia $i, con texto suficiente '
              'para que la tarjeta ocupe alto real en la pantalla.',
        ),
      );
    }
  }
  return OnDeviceBriefing(
    generatedAt: DateTime(2026, 8, 27, 8),
    articles: articles,
  );
}

Widget _app(OnDeviceBriefing briefing) => ProviderScope(
      overrides: [
        morningBriefingPreferencesProvider.overrideWithValue(
          FakeMorningBriefingPreferences(initialBriefing: briefing),
        ),
        localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: true)),
        sourceFetcherProvider.overrideWithValue(FakeSourceFetcher()),
        briefingNotificationsProvider.overrideWithValue(FakeBriefingNotifications()),
        briefingSchedulerProvider.overrideWithValue(FakeBriefingScheduler()),
        clockProvider.overrideWithValue(_FixedClock(DateTime(2026, 8, 27, 9))),
        appLanguageCodeProvider.overrideWithValue('es'),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MorningBriefingScreen(),
      ),
    );

Future<void> _openSection(WidgetTester tester, String section) async {
  final block = find.ancestor(of: find.text(section), matching: find.byType(Card));
  await tester.tap(find.descendant(of: block, matching: find.textContaining('Ver las ')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('una sección abierta sigue abierta al bajar y volver a subir',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(_tallBriefing()));
    await tester.pumpAndSettle();

    await _openSection(tester, 'Mundo');
    expect(find.text('Mundo noticia 1'), findsOneWidget);

    // Bajar hasta el final y volver: exactamente lo que hace el lector.
    final list = find.byType(Scrollable).first;
    await tester.fling(list, const Offset(0, -3000), 3000);
    await tester.pumpAndSettle();
    // La prueba solo vale si el framework DE VERDAD reciclo la seccion: si
    // sigue montada aqui, no estamos ejercitando el fallo que se reporto.
    expect(
      find.text('Mundo noticia 1'),
      findsNothing,
      reason: 'la sección tiene que haber salido del árbol para que la prueba signifique algo',
    );
    await tester.fling(list, const Offset(0, 3000), 3000);
    await tester.pumpAndSettle();

    expect(
      find.text('Mundo noticia 1'),
      findsOneWidget,
      reason: 'la sección que el lector abrió no puede cerrarse sola al desplazarse',
    );
  });

  testWidgets('abrir un resumen no lo cierra ni mueve la lista', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(_tallBriefing()));
    await tester.pumpAndSettle();
    await _openSection(tester, 'Mundo');

    final controller = tester
        .widget<Scrollable>(find.byType(Scrollable).first)
        .controller;

    await tester.ensureVisible(find.text('Mundo noticia 1'));
    await tester.pumpAndSettle();
    final before = controller?.position.pixels;

    // El Card mas INTERNO: el de la noticia. El de la seccion los envuelve a
    // todos, y buscar dentro de el encuentra los seis botones.
    final card = find
        .ancestor(of: find.text('Mundo noticia 1'), matching: find.byType(Card))
        .first;
    await tester.tap(
      find.descendant(of: card, matching: find.text('Ver resumen completo')),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: card, matching: find.text('Ocultar resumen completo')),
      findsOneWidget,
      reason: 'el panel que se acaba de abrir tiene que seguir abierto',
    );
    expect(
      controller?.position.pixels,
      before,
      reason: 'abrir un resumen no puede mandar al lector al final de la lista',
    );
  });

  testWidgets('varias secciones abiertas siguen abiertas al volver a subir',
      (tester) async {
    // El caso del lector: abre varios temas y va bajando. Cada ExpansionTile
    // guardaba su estado en la MISMA casilla de PageStorage (ninguno tenia
    // identidad propia), asi que la ultima en escribir decidia por todas.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(_tallBriefing()));
    await tester.pumpAndSettle();

    final list = find.byType(Scrollable).first;
    for (final section in ['Mundo', 'Tecnología', 'Ciencia', 'Deportes']) {
      await tester.scrollUntilVisible(find.text(section), 300, scrollable: list);
      await tester.pumpAndSettle();
      await _openSection(tester, section);
    }

    // Volver arriba, que es donde el lector dice que ya no encuentra nada abierto.
    await tester.fling(list, const Offset(0, 6000), 4000);
    await tester.pumpAndSettle();

    expect(
      find.text('Mundo noticia 1'),
      findsOneWidget,
      reason: 'la primera sección que abrió tiene que seguir abierta',
    );
  });

  testWidgets('un resumen abierto sigue abierto tras salir y volver a entrar '
      'en pantalla', (tester) async {
    // El segundo sintoma: "se abre pero de inmediato se cierra". El panel vivia
    // en el State de la tarjeta, que la lista perezosa destruye al reciclarla.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_app(_tallBriefing()));
    await tester.pumpAndSettle();
    await _openSection(tester, 'Mundo');

    final card = find
        .ancestor(of: find.text('Mundo noticia 1'), matching: find.byType(Card))
        .first;
    final abrir = find.descendant(of: card, matching: find.text('Ver resumen completo'));
    await tester.ensureVisible(abrir);
    await tester.pumpAndSettle();
    await tester.tap(abrir);
    await tester.pumpAndSettle();
    expect(find.text('Ocultar resumen completo'), findsOneWidget);

    final list = find.byType(Scrollable).first;
    await tester.fling(list, const Offset(0, -4000), 4000);
    await tester.pumpAndSettle();
    expect(find.text('Mundo noticia 1'), findsNothing, reason: 'salió del árbol');
    await tester.fling(list, const Offset(0, 6000), 4000);
    await tester.pumpAndSettle();

    expect(
      find.text('Ocultar resumen completo'),
      findsOneWidget,
      reason: 'el resumen que el lector abrió no puede cerrarse solo',
    );
  });

  testWidgets('el pliegue concuerda con cuántas noticias tiene detrás',
      (tester) async {
    await tester.pumpWidget(_app(OnDeviceBriefing(
      generatedAt: DateTime(2026, 8, 27, 8),
      articles: const [
        BriefingArticle(
          sourceName: 'Fuente',
          section: 'Mundo',
          title: 'Única de la mañana',
          url: 'https://ejemplo.com/1',
          description: 'Detalle',
        ),
        BriefingArticle(
          sourceName: 'Fuente',
          section: 'Ciencia',
          title: 'Una de ciencia',
          url: 'https://ejemplo.com/2',
          description: 'Detalle',
        ),
        BriefingArticle(
          sourceName: 'Fuente',
          section: 'Ciencia',
          title: 'Otra de ciencia',
          url: 'https://ejemplo.com/3',
          description: 'Detalle',
        ),
      ],
    )));
    await tester.pumpAndSettle();

    expect(find.text('Ver la noticia'), findsOneWidget);
    expect(find.text('Ver las 2 noticias'), findsOneWidget);
    expect(find.textContaining('Ver las 1'), findsNothing);
  });
}
