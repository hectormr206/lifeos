// Proves webSearchBackendProvider returns the right WebSearchBackend for the
// persisted provider preference: DuckDuckGo → DuckDuckGoBackend, SearXNG →
// SearxngBackend, None → a no-op backend that returns zero results. Uses a fake
// preferences store (no platform channel) + a noop fetcher (no network).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/morning_briefing/domain/source_fetcher.dart';
import 'package:lifeos/features/web_search/data/ddg_search_service.dart';
import 'package:lifeos/features/web_search/data/searxng_backend.dart';
import 'package:lifeos/features/web_search/domain/bundled_search_instance.dart';
import 'package:lifeos/features/web_search/domain/web_search_settings.dart';
import 'package:lifeos/features/web_search/presentation/web_search_providers.dart';

class _NoopFetcher implements SourceFetcher {
  @override
  Future<String> fetch(String url, {Map<String, String>? headers}) async => '';
}

class _FakePrefs implements WebSearchPreferences {
  _FakePrefs(this.settings);
  WebSearchSettings settings;

  @override
  Future<WebSearchSettings> load() async => settings;

  @override
  Future<void> save(WebSearchSettings s) async => settings = s;
}

Future<T> _backendFor<T>(
  WebSearchSettings settings, {
  BundledSearchInstance bundled =
      const BundledSearchInstance(baseUrl: '', accessKey: ''),
}) async {
  final container = ProviderContainer(overrides: [
    webSearchPreferencesProvider.overrideWithValue(_FakePrefs(settings)),
    webSearchFetcherProvider.overrideWithValue(_NoopFetcher()),
    bundledSearchInstanceProvider.overrideWithValue(bundled),
  ]);
  addTearDown(container.dispose);
  // Trigger the notifier build, then wait for async hydration to apply the
  // persisted settings before reading the derived backend.
  await container.read(webSearchSettingsProvider.notifier).ready;
  return container.read(webSearchBackendProvider) as T;
}

void main() {
  group('la instancia que trae la app', () {
    // Con LIFEOS_SEARCH_BASE_URL y LIFEOS_SEARCH_KEY compilados, el usuario no
    // tiene que pegar nada: elige "mi buscador" y ya funciona. Sin ellos —un
    // checkout— todo sigue exactamente como antes.
    test('sin URL propia usa la compilada, con su llave', () async {
      const bundled = BundledSearchInstance(
        baseUrl: 'https://search.example',
        accessKey: 'llave-secreta',
      );
      final backend = await _backendFor<SearxngBackend>(
        const WebSearchSettings(provider: WebSearchProvider.searxng),
        bundled: bundled,
      );

      expect(backend.baseUrl, 'https://search.example');
      expect(backend.accessKey, 'llave-secreta');
    });

    test('la URL del usuario gana sobre la compilada', () async {
      // Quien monta su propio SearXNG mandó a la app a otro sitio a propósito;
      // ignorarlo sería decidir por él a dónde van sus búsquedas.
      final backend = await _backendFor<SearxngBackend>(
        const WebSearchSettings(
          provider: WebSearchProvider.searxng,
          searxngBaseUrl: 'https://mio.casa',
        ),
        bundled: const BundledSearchInstance(
          baseUrl: 'https://search.example',
          accessKey: 'llave-secreta',
        ),
      );

      expect(backend.baseUrl, 'https://mio.casa');
    });

    test('a la instancia del usuario NO se le manda nuestra llave', () async {
      // La llave abre nuestra puerta y sólo la nuestra. Enviarla a un servidor
      // ajeno la regala sin que nadie se entere.
      final backend = await _backendFor<SearxngBackend>(
        const WebSearchSettings(
          provider: WebSearchProvider.searxng,
          searxngBaseUrl: 'https://mio.casa',
        ),
        bundled: const BundledSearchInstance(
          baseUrl: 'https://search.example',
          accessKey: 'llave-secreta',
        ),
      );

      expect(backend.accessKey, isEmpty);
    });

    test('sin nada compilado y sin URL, se queda como estaba', () async {
      final backend = await _backendFor<SearxngBackend>(
        const WebSearchSettings(provider: WebSearchProvider.searxng),
        bundled: const BundledSearchInstance(baseUrl: '', accessKey: ''),
      );

      expect(backend.baseUrl, isEmpty);
      expect(backend.accessKey, isEmpty);
    });
  });

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
