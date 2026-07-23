import 'package:shared_preferences/shared_preferences.dart';

/// Which web-search backend the user has chosen for the chat's "buscar en
/// internet" mode.
///
/// * [duckduckgo] — the public DuckDuckGo-lite scrape. DEFAULT: works with zero
///   configuration, no account, best-effort. Nothing of the user's data leaves
///   beyond the query itself.
/// * [searxng] — the user's OWN SearXNG instance (private metasearch on a host
///   they control). Requires a base URL.
/// * [none] — web search fully OFF. The chat globe toggle is hidden and NO
///   outbound search request is ever made.
///
/// The persistence below round-trips any value by its [Enum.name]; unknown /
/// never-set falls back to [duckduckgo].
enum WebSearchProvider { duckduckgo, searxng, none }

/// The persisted web-search configuration: the chosen [provider] and, for the
/// SearXNG option, the instance [searxngBaseUrl].
class WebSearchSettings {
  const WebSearchSettings({
    this.provider = WebSearchProvider.duckduckgo,
    this.searxngBaseUrl = '',
  });

  final WebSearchProvider provider;
  final String searxngBaseUrl;

  WebSearchSettings copyWith({WebSearchProvider? provider, String? searxngBaseUrl}) =>
      WebSearchSettings(
        provider: provider ?? this.provider,
        searxngBaseUrl: searxngBaseUrl ?? this.searxngBaseUrl,
      );

  @override
  bool operator ==(Object other) =>
      other is WebSearchSettings &&
      other.provider == provider &&
      other.searxngBaseUrl == searxngBaseUrl;

  @override
  int get hashCode => Object.hash(provider, searxngBaseUrl);

  @override
  String toString() => 'WebSearchSettings($provider, "$searxngBaseUrl")';
}

/// Local-only persistence for [WebSearchSettings].
///
/// Deliberately NOT `flutter_secure_storage`: the search provider + instance URL
/// are non-secret UI preferences that MUST survive with no engine connection /
/// no pairing (mirrors [LanguagePreferences] / [VoiceReplyPreferences]).
/// Abstracted so the notifier depends on the interface and tests inject a fake
/// without the platform channel.
abstract class WebSearchPreferences {
  /// The persisted settings; defaults ([WebSearchProvider.duckduckgo], empty
  /// URL) when never set.
  Future<WebSearchSettings> load();

  /// Persists [settings].
  Future<void> save(WebSearchSettings settings);
}

/// [WebSearchPreferences] backed by `shared_preferences`.
class SharedPrefsWebSearchPreferences implements WebSearchPreferences {
  SharedPrefsWebSearchPreferences({SharedPreferences? prefs}) : _prefs = prefs; // ignore: prefer_initializing_formals

  static const String providerKey = 'web_search_provider';
  static const String searxngUrlKey = 'web_search_searxng_url';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _instance async => _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<WebSearchSettings> load() async {
    final prefs = await _instance;
    return WebSearchSettings(
      provider: _decode(prefs.getString(providerKey)),
      searxngBaseUrl: prefs.getString(searxngUrlKey) ?? '',
    );
  }

  @override
  Future<void> save(WebSearchSettings settings) async {
    final prefs = await _instance;
    await prefs.setString(providerKey, settings.provider.name);
    await prefs.setString(searxngUrlKey, settings.searxngBaseUrl);
  }

  static WebSearchProvider _decode(String? raw) {
    for (final value in WebSearchProvider.values) {
      if (value.name == raw) return value;
    }
    // Unknown / never-set → the zero-config default.
    return WebSearchProvider.duckduckgo;
  }
}
