// Proves the on-device Boletín screen UX polish: each source renders as a
// COLLAPSIBLE accordion header "<Source> (<count>)" (collapsed by default,
// expanding to reveal the item cards), and an item with no brief shows a subtle
// hint instead of an empty box.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_notifier.dart'
    show hnFrontPageUrl;
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_providers.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:lifeos/l10n/locale_providers.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../local_model/support/fake_local_llm_engine.dart';
import '../support/fakes.dart';

/// RFC-822 timestamp so a feed item lands inside the freshness window.
String _rfc822(DateTime dt) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final u = dt.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(u.day)} ${months[u.month - 1]} ${u.year} ${two(u.hour)}:${two(u.minute)}:00 GMT';
}

class _FixedClock implements Clock {
  const _FixedClock(this._now);
  final DateTime _now;
  @override
  DateTime now() => _now;
}

OnDeviceBriefing _briefing() => OnDeviceBriefing(
      generatedAt: DateTime(2026, 7, 22, 8),
      articles: const [
        BriefingArticle(
          sourceName: 'Fuente A',
          section: 'Mundo',
          title: 'Primera noticia de hoy',
          url: 'https://a.com/1',
          description: 'Detalle de la primera noticia',
        ),
        BriefingArticle(
          sourceName: 'Fuente A',
          section: 'Mundo',
          title: 'Segunda de la mañana',
          url: 'https://a.com/2',
          description: 'Detalle de la segunda',
        ),
        BriefingArticle(
          sourceName: 'Hacker News',
          section: 'Tecnología',
          title: 'Historia de última hora',
          url: 'https://news.ycombinator.com/item?id=1',
          hnObjectId: '1',
          // No feed brief → the hint should render in its place.
        ),
      ],
    );

/// A briefing whose first article carries an eager translation and whose second
/// does not — to prove translated-by-default rendering with native fallback.
OnDeviceBriefing _translatedBriefing() => OnDeviceBriefing(
      generatedAt: DateTime(2026, 7, 22, 8),
      articles: const [
        BriefingArticle(
          sourceName: 'English Source',
          section: 'Mundo',
          title: 'The Future of AI',
          url: 'https://en.com/1',
          description: 'A look at the future',
          translatedTitle: 'El futuro de la IA',
          translatedDescription: 'Un vistazo al futuro',
        ),
        BriefingArticle(
          sourceName: 'English Source',
          section: 'Mundo',
          title: 'Untranslated Headline',
          url: 'https://en.com/2',
          description: 'Some brief',
          // No translation → falls back to the native English text.
        ),
      ],
    );

/// Opens the fold of the theme block titled [section].
///
/// The briefing is read by THEME now, so a test that wants a card first has to
/// unfold its section — the same two steps the reader takes.
Future<void> _openSection(WidgetTester tester, String section) async {
  final block = find.ancestor(
    of: find.text(section),
    matching: find.byType(Card),
  );
  await tester.tap(
    find.descendant(of: block, matching: find.textContaining('Ver las ')),
  );
  await tester.pumpAndSettle();
}

/// Wraps [app] in the fully faked provider scope. Returns the whole scoped
/// widget rather than a bare override list because Riverpod 3 does not export
/// `Override` publicly, so a `List<Override>` helper cannot be given a real
/// return type.
Widget _scoped(
  Widget app, {
  OnDeviceBriefing? briefing,
  FakeLocalLlmEngine? engine,
  FakeSourceFetcher? fetcher,
  List<String> sources = const [],
}) =>
    ProviderScope(
      overrides: [
        morningBriefingPreferencesProvider.overrideWithValue(
          FakeMorningBriefingPreferences(
            initialBriefing: briefing ?? _briefing(),
            initialSources: sources,
          ),
        ),
        localLlmEngineProvider.overrideWithValue(engine ?? FakeLocalLlmEngine(installed: true)),
        sourceFetcherProvider.overrideWithValue(fetcher ?? FakeSourceFetcher()),
        briefingNotificationsProvider.overrideWithValue(FakeBriefingNotifications()),
        briefingSchedulerProvider.overrideWithValue(FakeBriefingScheduler()),
        clockProvider.overrideWithValue(_FixedClock(DateTime(2026, 7, 22, 9))),
        // The screen renders Spanish copy; pin the pipeline's target language
        // to match, so an English feed is genuinely something to translate.
        appLanguageCodeProvider.overrideWithValue('es'),
      ],
      child: app,
    );

Widget _app([
  OnDeviceBriefing? briefing,
  FakeLocalLlmEngine? engine,
  FakeSourceFetcher? fetcher,
  List<String> sources = const [],
]) =>
    _scoped(
      const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MorningBriefingScreen(),
      ),
      briefing: briefing,
      engine: engine,
      fetcher: fetcher,
      sources: sources,
    );

/// The same screen behind a real [GoRouter], so a deep link out of the card
/// (the "descargar un modelo" action) can actually be followed in a test.
Widget _routerApp(GoRouter router, [FakeLocalLlmEngine? engine]) => _scoped(
      MaterialApp.router(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
      engine: engine,
    );

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.physicalSize = const Size(1000, 3200);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  testWidgets('renders a collapsible header "<Source> (<count>)" per source', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Cabecera por TEMA, con las fuentes que lo alimentan acreditadas debajo.
    expect(find.text('Mundo'), findsOneWidget);
    expect(find.text('Tecnología'), findsOneWidget);
    expect(find.text('Fuente A'), findsOneWidget);
    expect(find.text('Hacker News'), findsOneWidget);
  });

  testWidgets('los temas vienen PLEGADOS y se abren al tocar', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Collapsed: the item cards are not visible (offstage children are skipped).
    expect(find.text('Primera noticia de hoy'), findsNothing);

    await _openSection(tester, 'Mundo');

    // Expanded: the source's cards are revealed.
    expect(find.text('Primera noticia de hoy'), findsOneWidget);
    expect(find.text('Segunda de la mañana'), findsOneWidget);
  });

  testWidgets('renders the translation by default, falling back to native text', (tester) async {
    await tester.pumpWidget(_app(_translatedBriefing()));
    await tester.pumpAndSettle();

    await _openSection(tester, 'Mundo');

    // First article: shows the cached Spanish translation, not the English title.
    expect(find.text('El futuro de la IA'), findsOneWidget);
    expect(find.text('Un vistazo al futuro'), findsOneWidget);
    expect(find.text('The Future of AI'), findsNothing);
    // Second article: no translation → falls back to the native English text.
    expect(find.text('Untranslated Headline'), findsOneWidget);
  });

  testWidgets('an item with no brief shows the subtle hint (not an empty box)', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await _openSection(tester, 'Tecnología');

    expect(find.text('Historia de última hora'), findsOneWidget);
    expect(find.textContaining('Sin resumen'), findsOneWidget);
  });

  // THE REPORTED BUG. The link reads "Ver noticia completa →" and the user taps
  // it expecting the article. It copied the URL to the clipboard instead —
  // leaving them to paste it somewhere by hand. A label that names an action
  // must perform that action.
  testWidgets('"Ver noticia completa" OPENS the article, it does not copy it',
      (tester) async {
    final launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _openSection(tester, 'Mundo');

    await tester.tap(find.text('Ver noticia completa →').first);
    await tester.pumpAndSettle();

    expect(launcher.launched, ['https://a.com/1']);
    // And no "link copied" consolation prize.
    expect(find.textContaining('opiad'), findsNothing);
  });

  testWidgets('it opens in the EXTERNAL browser, never an in-app webview',
      (tester) async {
    final launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _openSection(tester, 'Mundo');
    await tester.tap(find.text('Ver noticia completa →').first);
    await tester.pumpAndSettle();

    expect(launcher.lastUseWebView, isFalse);
  });

  testWidgets('when the article cannot be opened, it SAYS so and offers to copy',
      (tester) async {
    // Silence is the wrong answer: a tap that does nothing looks like a frozen
    // app. Copying is a genuine fallback, but only when announced.
    final launcher = _FakeUrlLauncher(canOpen: false);
    UrlLauncherPlatform.instance = launcher;

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await _openSection(tester, 'Mundo');
    await tester.tap(find.text('Ver noticia completa →').first);
    await tester.pumpAndSettle();

    expect(launcher.launched, isEmpty);
    // Says so out loud, and offers copying as an explicit choice rather than
    // doing it silently.
    expect(find.text('No se pudo abrir la noticia.'), findsOneWidget);
    expect(find.text('Copiar enlace'), findsOneWidget);
  });

  // THE REPORTED BUG. Two taps in quick succession used to leave the first
  // summary cut short. Now the second WAITS — and the card has to say so, or
  // the wait is indistinguishable from a dead tap.
  testWidgets('a second summary tap shows "en cola" while the first one runs',
      (tester) async {
    final gate = Completer<void>();
    final engine = FakeLocalLlmEngine(
      installed: true,
      generateGate: gate,
      reply: (_) => 'Resumen listo',
    );
    const page = '<html><body><p>Cuerpo del artículo largo y legible.</p></body></html>';
    final fetcher = FakeSourceFetcher(bodies: {
      'https://a.com/1': page,
      'https://a.com/2': page,
    });

    await tester.pumpWidget(_app(_briefing(), engine, fetcher));
    await tester.pumpAndSettle();
    await _openSection(tester, 'Mundo');

    await tester.tap(find.text('Ver resumen completo').first);
    await tester.pump();
    await tester.tap(find.text('Ver resumen completo').last);
    await tester.pump();
    await tester.pump();

    // The first is running, the second is visibly waiting its turn.
    expect(find.text('Resumiendo…'), findsOneWidget);
    expect(find.text('En cola…'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    // Both finish; nothing was dropped.
    expect(find.text('Resumen listo'), findsNWidgets(2));
    expect(find.text('En cola…'), findsNothing);
    expect(find.text('Resumiendo…'), findsNothing);
  });

  // THE REPORTED BUG (build 799). Every failure read "No se pudo generar el
  // resumen. Inténtalo de nuevo.", there was no way to try again except
  // collapsing and reopening the panel, and the retry failed so fast that the
  // screen never appeared to change.
  group('a failed summary says WHAT failed and what to do about it', () {
    /// Opens "Fuente A" and taps the first "Ver resumen completo".
    Future<void> requestFirstSummary(WidgetTester tester) async {
      await _openSection(tester, 'Mundo');
      await tester.tap(find.text('Ver resumen completo').first);
      await tester.pumpAndSettle();
    }

    testWidgets('no model installed: it says so and offers the DOWNLOAD, not a retry',
        (tester) async {
      await tester.pumpWidget(_app(_briefing(), FakeLocalLlmEngine(installed: false)));
      await tester.pumpAndSettle();
      await requestFirstSummary(tester);

      expect(find.textContaining('no hay ningún modelo instalado'), findsOneWidget);
      expect(find.text('Descargar un modelo'), findsOneWidget);
      expect(find.text('Reintentar'), findsNothing,
          reason: 'without a model, a retry fails identically forever');
    });

    testWidgets('the download action opens the local-model screen', (tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const MorningBriefingScreen()),
          GoRoute(
            path: '/settings/local-model',
            builder: (_, _) => const Scaffold(body: Text('pantalla del modelo')),
          ),
        ],
      );
      await tester.pumpWidget(_routerApp(router, FakeLocalLlmEngine(installed: false)));
      await tester.pumpAndSettle();
      await requestFirstSummary(tester);

      await tester.tap(find.text('Descargar un modelo'));
      await tester.pumpAndSettle();

      expect(find.text('pantalla del modelo'), findsOneWidget);
    });

    testWidgets('an unreadable page says it is permanent and offers no retry', (tester) async {
      final fetcher = FakeSourceFetcher(bodies: {'https://a.com/1': '<html><body></body></html>'});
      await tester.pumpWidget(
          _app(_briefing(), FakeLocalLlmEngine(installed: true), fetcher));
      await tester.pumpAndSettle();
      await requestFirstSummary(tester);

      expect(find.textContaining('no tiene texto legible'), findsOneWidget);
      expect(find.text('Reintentar'), findsNothing);
      expect(find.text('Reintentar no cambiaría el resultado.'), findsOneWidget);
    });

    testWidgets('reopening the panel does NOT silently re-run a permanent failure',
        (tester) async {
      // Collapsing and reopening used to be the ONLY way to retry, so it
      // re-ran everything. For a page that will never be readable that is a
      // pointless fetch the user did not ask for.
      final fetcher = FakeSourceFetcher(bodies: {'https://a.com/1': '<html><body></body></html>'});
      await tester.pumpWidget(_app(_briefing(), FakeLocalLlmEngine(installed: true), fetcher));
      await tester.pumpAndSettle();
      await requestFirstSummary(tester);
      expect(fetcher.fetched.where((u) => u == 'https://a.com/1').length, 1);

      await tester.tap(find.text('Ocultar resumen completo').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ver resumen completo').first);
      await tester.pumpAndSettle();

      expect(fetcher.fetched.where((u) => u == 'https://a.com/1').length, 1);
      // …and the explanation is still there when it reopens.
      expect(find.textContaining('no tiene texto legible'), findsOneWidget);
    });

    testWidgets('a transient failure offers "Reintentar", and a repeat failure is visible',
        (tester) async {
      // The page cannot be fetched: a real "try again" case.
      final engine = FakeLocalLlmEngine(installed: true);
      final fetcher = FakeSourceFetcher(failing: {'https://a.com/1'});
      await tester.pumpWidget(_app(_briefing(), engine, fetcher));
      await tester.pumpAndSettle();
      await requestFirstSummary(tester);

      expect(find.textContaining('No se pudo descargar la página'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      // First failure: no attempt line to shout about yet.
      expect(find.textContaining('Volvió a fallar'), findsNothing);

      await tester.tap(find.text('Reintentar'));
      await tester.pumpAndSettle();

      // It really ran again, and the card SAYS so — otherwise the identical
      // red line reads as a tap that did nothing.
      expect(fetcher.fetched.where((u) => u == 'https://a.com/1').length, 2);
      expect(find.text('Volvió a fallar (intento 2).'), findsOneWidget);
    });
  });

  // ─── THE EVIDENCE, ONE TAP AWAY ─────────────────────────────────────────
  //
  // "Hay un modelo instalado, pero no se pudo usar…" is the right headline and
  // stays the headline. But it was also the END of the evidence: the real
  // exception died in a `catch (_)`, and on the device where this happens
  // there is no way to recover it. It now survives to a COLLAPSED affordance
  // the user can expand and quote back.
  group('the underlying exception is reachable, and never the headline', () {
    Future<void> requestFirstSummary(WidgetTester tester) async {
      await _openSection(tester, 'Mundo');
      await tester.tap(find.text('Ver resumen completo').first);
      await tester.pumpAndSettle();
    }

    testWidgets('a load failure hides its details behind one collapsed tap', (tester) async {
      final engine = FakeLocalLlmEngine(installed: true, loadShouldFail: true);
      await tester.pumpWidget(_app(_briefing(), engine));
      await tester.pumpAndSettle();
      await requestFirstSummary(tester);

      // The plain-language sentence is the headline…
      expect(find.textContaining('no se pudo usar'), findsOneWidget);
      // …and the exception is NOT shown by default.
      expect(find.textContaining('load boom'), findsNothing);
      expect(find.text('Ver detalles técnicos'), findsOneWidget);

      await tester.tap(find.text('Ver detalles técnicos'));
      await tester.pumpAndSettle();

      // Which call threw, its type, and what it said.
      expect(find.textContaining('load'), findsWidgets);
      expect(find.textContaining('load boom'), findsOneWidget);
      expect(find.text('Ocultar detalles técnicos'), findsOneWidget);
      // The headline never moved.
      expect(find.textContaining('no se pudo usar'), findsOneWidget);
    });

    testWidgets('a generate failure names generate, not load', (tester) async {
      final engine = FakeLocalLlmEngine(installed: true, generateShouldFail: true);
      const page = '<html><body><p>Cuerpo del artículo largo y legible.</p></body></html>';
      await tester.pumpWidget(
        _app(_briefing(), engine, FakeSourceFetcher(bodies: {'https://a.com/1': page})),
      );
      await tester.pumpAndSettle();
      await requestFirstSummary(tester);

      await tester.tap(find.text('Ver detalles técnicos'));
      await tester.pumpAndSettle();

      expect(find.textContaining('generate boom'), findsOneWidget);
    });

    testWidgets('the details can be copied, and the copy is confirmed', (tester) async {
      final engine = FakeLocalLlmEngine(installed: true, loadShouldFail: true);
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(_app(_briefing(), engine));
      await tester.pumpAndSettle();
      await requestFirstSummary(tester);
      await tester.tap(find.text('Ver detalles técnicos'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Copiar detalles'));
      await tester.pumpAndSettle();

      expect(copied, hasLength(1));
      expect(copied.single, contains('load boom'));
      expect(find.text('Detalles técnicos copiados.'), findsOneWidget);
    });

    // A cause identified without ever touching the model has no exception to
    // show, and an empty "details" affordance would promise evidence that does
    // not exist.
    testWidgets('a non-model failure offers no details affordance', (tester) async {
      final fetcher = FakeSourceFetcher(bodies: {'https://a.com/1': '<html><body></body></html>'});
      await tester.pumpWidget(_app(_briefing(), FakeLocalLlmEngine(installed: true), fetcher));
      await tester.pumpAndSettle();
      await requestFirstSummary(tester);

      expect(find.textContaining('no tiene texto legible'), findsOneWidget);
      expect(find.text('Ver detalles técnicos'), findsNothing);
    });
  });

  // ─── THE SAME SILENCE, IN THE TRANSLATION ───────────────────────────────
  group('untranslated items say why', () {
    testWidgets('an engine that will not load explains the original-language items',
        (tester) async {
      final engine = FakeLocalLlmEngine(installed: true, loadShouldFail: true);
      // An English feed the model would have to translate, and an engine that
      // cannot load: the items survive in English, and the reason is said.
      final fetcher = FakeSourceFetcher(bodies: {
        'https://en.com/rss': '<rss version="2.0"><channel><title>English Source</title>'
            '<item><title>The Future of AI</title><link>https://en.com/1</link>'
            '<description>A look at the future</description>'
            '<pubDate>${_rfc822(DateTime(2026, 7, 22, 6))}</pubDate></item>'
            '</channel></rss>',
        hnFrontPageUrl: '{"hits":[]}',
      });
      await tester.pumpWidget(
        _app(_briefing(), engine, fetcher, const ['https://en.com/rss']),
      );
      await tester.pumpAndSettle();
      // Regenerate so the translation stage actually runs against the engine.
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Sanity: the regenerated briefing really is the English feed — el bloque
      // acredita a su fuente debajo del tema.
      expect(find.text('English Source'), findsOneWidget);
      expect(find.textContaining('idioma original'), findsOneWidget);
      expect(find.text('Ver detalles técnicos'), findsOneWidget);

      await tester.tap(find.text('Ver detalles técnicos'));
      await tester.pumpAndSettle();
      expect(find.textContaining('load boom'), findsOneWidget);
    });
  });

  // ─── THE COST OF THE FALLBACK, WHERE THE WAITING HAPPENS ────────────────
  group('a model on the fallback backend says the wait is longer', () {
    testWidgets('the notice rides the RUNNING panel, not a settings screen', (tester) async {
      final gate = Completer<void>();
      final engine = FakeLocalLlmEngine(
        installed: true,
        generateGate: gate,
        reply: (_) => 'Resumen listo',
      )..usesFallbackBackend = true;
      const page = '<html><body><p>Cuerpo del artículo largo y legible.</p></body></html>';
      await tester.pumpWidget(
        _app(_briefing(), engine, FakeSourceFetcher(bodies: {'https://a.com/1': page})),
      );
      await tester.pumpAndSettle();
      await _openSection(tester, 'Mundo');

      await tester.tap(find.text('Ver resumen completo').first);
      await tester.pump();
      await tester.pump();

      expect(find.text('Resumiendo…'), findsOneWidget);
      expect(find.textContaining('sin aceleración por hardware'), findsOneWidget);

      gate.complete();
      await tester.pumpAndSettle();

      // Once the summary is there, the wait is over and so is the notice.
      expect(find.text('Resumen listo'), findsOneWidget);
      expect(find.textContaining('sin aceleración por hardware'), findsNothing);
    });

    testWidgets('an ordinary load says nothing about acceleration', (tester) async {
      final gate = Completer<void>();
      final engine = FakeLocalLlmEngine(
        installed: true,
        generateGate: gate,
        reply: (_) => 'Resumen listo',
      );
      const page = '<html><body><p>Cuerpo del artículo largo y legible.</p></body></html>';
      await tester.pumpWidget(
        _app(_briefing(), engine, FakeSourceFetcher(bodies: {'https://a.com/1': page})),
      );
      await tester.pumpAndSettle();
      await _openSection(tester, 'Mundo');
      await tester.tap(find.text('Ver resumen completo').first);
      await tester.pump();
      await tester.pump();

      expect(find.text('Resumiendo…'), findsOneWidget);
      expect(find.textContaining('sin aceleración por hardware'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();
    });
  });
}

/// Records launched URLs so the article link can be verified without a real
/// browser. [canOpen] false simulates a device with nothing able to handle it.
class _FakeUrlLauncher extends Fake with MockPlatformInterfaceMixin implements UrlLauncherPlatform {
  _FakeUrlLauncher({this.canOpen = true});

  final bool canOpen;
  final List<String> launched = [];
  bool? lastUseWebView;

  @override
  Future<bool> canLaunch(String url) async => canOpen;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    if (!canOpen) return false;
    launched.add(url);
    lastUseWebView = options.mode == PreferredLaunchMode.inAppWebView;
    return true;
  }
}
