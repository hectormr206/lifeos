// Proves webSearchBackendProvider returns the right WebSearchBackend for the
// persisted provider preference: DuckDuckGo → DuckDuckGoBackend, SearXNG →
// SearxngBackend, None → a no-op backend that returns zero results. Uses a fake
// preferences store (no platform channel) + a noop fetcher (no network).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/source_fetcher.dart';
import 'package:lifeos/features/web_search/data/ddg_search_service.dart';
import 'package:lifeos/features/web_search/data/searxng_backend.dart';
import 'package:lifeos/features/web_search/domain/web_search_settings.dart';
import 'package:lifeos/features/web_search/presentation/web_search_providers.dart';

class _NoopFetcher implements SourceFetcher {
  @override
  Future<String> fetch(String url) async => '';
}

class _FakePrefs implements WebSearchPreferences {
  _FakePrefs(this.settings);
  WebSearchSettings settings;

  @override
  Future<WebSearchSettings> load() async => settings;

  @override
  Future<void> save(WebSearchSettings s) async => settings = s;
}

Future<T> _backendFor<T>(WebSearchSettings settings) async {
  final container = ProviderContainer(overrides: [
    webSearchPreferencesProvider.overrideWithValue(_FakePrefs(settings)),
    webSearchFetcherProvider.overrideWithValue(_NoopFetcher()),
  ]);
  addTearDown(container.dispose);
  // Trigger the notifier build, then wait for async hydration to apply the
  // persisted settings before reading the derived backend.
  await container.read(webSearchSettingsProvider.notifier).ready;
  return container.read(webSearchBackendProvider) as T;
}

void main() {
  test('DuckDuckGo preference → DuckDuckGoBackend', () async {
    final backend = await _backendFor(const WebSearchSettings());
    expect(backend, isA<DuckDuckGoBackend>());
  });

  test('SearXNG preference → SearxngBackend', () async {
    final backend = await _backendFor<Object>(const WebSearchSettings(
      provider: WebSearchProvider.searxng,
      searxngBaseUrl: 'https://searx.example',
    ));
    expect(backend, isA<SearxngBackend>());
  });

  test('None preference → a backend that returns zero results', () async {
    final backend = await _backendFor(const WebSearchSettings(provider: WebSearchProvider.none));
    expect(await backend.search('anything'), isEmpty);
  });
}
