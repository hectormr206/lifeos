// Proves the on-device Boletín screen UX polish: each source renders as a
// COLLAPSIBLE accordion header "<Source> (<count>)" (collapsed by default,
// expanding to reveal the item cards), and an item with no brief shows a subtle
// hint instead of an empty box.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/clock/clock.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';
import 'package:lifeos/features/morning_briefing/domain/morning_briefing.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_providers.dart';
import 'package:lifeos/features/morning_briefing/presentation/morning_briefing_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

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

Widget _app([OnDeviceBriefing? briefing]) => ProviderScope(
      overrides: [
        morningBriefingPreferencesProvider.overrideWithValue(
          FakeMorningBriefingPreferences(initialBriefing: briefing ?? _briefing()),
        ),
        localLlmEngineProvider.overrideWithValue(FakeLocalLlmEngine(installed: true)),
        sourceFetcherProvider.overrideWithValue(FakeSourceFetcher()),
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
}
