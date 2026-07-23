// Proves SharedPrefsWebSearchPreferences round-trips the chosen provider and
// SearXNG URL, and defaults to DuckDuckGo when nothing is stored — using
// shared_preferences' in-memory mock (no platform channel).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/web_search/domain/web_search_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to DuckDuckGo with an empty URL when nothing is stored', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsWebSearchPreferences();

    final settings = await prefs.load();
    expect(settings.provider, WebSearchProvider.duckduckgo);
    expect(settings.searxngBaseUrl, '');
  });

  test('persists and reads back the provider + SearXNG URL', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsWebSearchPreferences();

    await prefs.save(const WebSearchSettings(
      provider: WebSearchProvider.searxng,
      searxngBaseUrl: 'https://searx.example',
    ));

    final loaded = await prefs.load();
    expect(loaded.provider, WebSearchProvider.searxng);
    expect(loaded.searxngBaseUrl, 'https://searx.example');
  });

  test('round-trips the "none" provider', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = SharedPrefsWebSearchPreferences();

    await prefs.save(const WebSearchSettings(provider: WebSearchProvider.none));
    expect((await prefs.load()).provider, WebSearchProvider.none);
  });

  test('falls back to DuckDuckGo on an unknown stored provider value', () async {
    SharedPreferences.setMockInitialValues({'web_search_provider': 'bogus'});
    final prefs = SharedPrefsWebSearchPreferences();
    expect((await prefs.load()).provider, WebSearchProvider.duckduckgo);
  });
}
