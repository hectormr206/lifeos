// Proves the on-device Boletín screen UX polish: each source renders as a
// COLLAPSIBLE accordion header "<Source> (<count>)" (collapsed by default,
// expanding to reveal the item cards), and an item with no brief shows a subtle
// hint instead of an empty box.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_providers.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../local_model/support/fake_local_llm_engine.dart';
import '../support/fakes.dart';

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
          title: 'Primera noticia de hoy',
          url: 'https://a.com/1',
          description: 'Detalle de la primera noticia',
        ),
        BriefingArticle(
          sourceName: 'Fuente A',
          title: 'Segunda de la mañana',
          url: 'https://a.com/2',
          description: 'Detalle de la segunda',
        ),
        BriefingArticle(
          sourceName: 'Hacker News',
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
          title: 'The Future of AI',
          url: 'https://en.com/1',
          description: 'A look at the future',
          translatedTitle: 'El futuro de la IA',
          translatedDescription: 'Un vistazo al futuro',
        ),
        BriefingArticle(
          sourceName: 'English Source',
          title: 'Untranslated Headline',
          url: 'https://en.com/2',
          description: 'Some brief',
          // No translation → falls back to the native English text.
        ),
      ],
    );

Widget _app([
  OnDeviceBriefing? briefing,
  FakeLocalLlmEngine? engine,
  FakeSourceFetcher? fetcher,
]) =>
    ProviderScope(
      overrides: [
        morningBriefingPreferencesProvider.overrideWithValue(
          FakeMorningBriefingPreferences(initialBriefing: briefing ?? _briefing()),
        ),
        localLlmEngineProvider
            .overrideWithValue(engine ?? FakeLocalLlmEngine(installed: true)),
        sourceFetcherProvider.overrideWithValue(fetcher ?? FakeSourceFetcher()),
        briefingNotificationsProvider.overrideWithValue(FakeBriefingNotifications()),
        briefingSchedulerProvider.overrideWithValue(FakeBriefingScheduler()),
        clockProvider.overrideWithValue(_FixedClock(DateTime(2026, 7, 22, 9))),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MorningBriefingScreen(),
      ),
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

    // Header shows the source name + its item count.
    expect(find.text('Fuente A (2)'), findsOneWidget);
    expect(find.text('Hacker News (1)'), findsOneWidget);
  });

  testWidgets('sources are COLLAPSED by default and expand on tap', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // Collapsed: the item cards are not visible (offstage children are skipped).
    expect(find.text('Primera noticia de hoy'), findsNothing);

    await tester.tap(find.text('Fuente A (2)'));
    await tester.pumpAndSettle();

    // Expanded: the source's cards are revealed.
    expect(find.text('Primera noticia de hoy'), findsOneWidget);
    expect(find.text('Segunda de la mañana'), findsOneWidget);
  });

  testWidgets('renders the translation by default, falling back to native text', (tester) async {
    await tester.pumpWidget(_app(_translatedBriefing()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('English Source (2)'));
    await tester.pumpAndSettle();

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

    await tester.tap(find.text('Hacker News (1)'));
    await tester.pumpAndSettle();

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
    await tester.tap(find.text('Fuente A (2)'));
    await tester.pumpAndSettle();

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
    await tester.tap(find.text('Fuente A (2)'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.text('Fuente A (2)'));
    await tester.pumpAndSettle();
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
    await tester.tap(find.text('Fuente A (2)'));
    await tester.pumpAndSettle();

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
