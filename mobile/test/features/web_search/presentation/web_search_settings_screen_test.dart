// Proves the "Búsqueda web" settings screen: selecting SearXNG reveals the URL
// field + "Probar conexión", and the test button reports success (instance
// answers with results) or failure (unreachable) — all against a fake fetcher,
// no network.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/source_fetcher.dart';
import 'package:lifeos/features/web_search/domain/web_search_settings.dart';
import 'package:lifeos/features/web_search/presentation/web_search_providers.dart';
import 'package:lifeos/features/web_search/presentation/web_search_settings_screen.dart';
import 'package:lifeos/l10n/app_localizations.dart';

const _searxngJson = '''
{"results": [{"url": "https://news.example/a", "title": "Alpha"}]}
''';

/// Answers every request with a valid SearXNG JSON body → connection succeeds.
class _OkFetcher implements SourceFetcher {
  @override
  Future<String> fetch(String url) async => _searxngJson;
}

/// Throws for everything → connection fails.
class _DownFetcher implements SourceFetcher {
  @override
  Future<String> fetch(String url) async => throw Exception('unreachable');
}

class _FakePrefs implements WebSearchPreferences {
  _FakePrefs(this.settings);
  WebSearchSettings settings;
  @override
  Future<WebSearchSettings> load() async => settings;
  @override
  Future<void> save(WebSearchSettings s) async => settings = s;
}

Widget _app() => const MaterialApp(
      home: WebSearchSettingsScreen(),
      locale: Locale('es'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );

Future<void> _pumpSearxng(WidgetTester tester, SourceFetcher fetcher) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      webSearchPreferencesProvider.overrideWithValue(
        _FakePrefs(const WebSearchSettings(
          provider: WebSearchProvider.searxng,
          searxngBaseUrl: 'https://searx.example',
        )),
      ),
      webSearchFetcherProvider.overrideWithValue(fetcher),
    ],
    child: _app(),
  ));
  final container = ProviderScope.containerOf(tester.element(find.byType(WebSearchSettingsScreen)));
  await container.read(webSearchSettingsProvider.notifier).ready;
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('SearXNG selected shows the URL field and the test button', (tester) async {
    await _pumpSearxng(tester, _OkFetcher());

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Probar conexión'), findsOneWidget);
  });

  testWidgets('"Probar conexión" reports success when the instance answers', (tester) async {
    await _pumpSearxng(tester, _OkFetcher());

    await tester.tap(find.text('Probar conexión'));
    await tester.pump(); // start the async test (spinner)
    await tester.pumpAndSettle(); // let it resolve

    expect(find.text('Conexión exitosa'), findsOneWidget);
    expect(find.text('No se pudo conectar'), findsNothing);
  });

  testWidgets('"Probar conexión" reports failure when the instance is unreachable', (tester) async {
    await _pumpSearxng(tester, _DownFetcher());

    await tester.tap(find.text('Probar conexión'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('No se pudo conectar'), findsOneWidget);
    expect(find.text('Conexión exitosa'), findsNothing);
  });
}
