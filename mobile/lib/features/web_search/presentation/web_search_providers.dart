import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/presentation/chat_providers.dart';
import '../../morning_briefing/data/dio_source_fetcher.dart';
import '../../morning_briefing/domain/source_fetcher.dart';
import '../data/ddg_search_service.dart';
import '../data/searxng_backend.dart';
import '../data/web_search_pipeline.dart';
import '../domain/web_search_backend.dart';
import '../domain/web_search_settings.dart';

/// The FRESH, unpaired HTTP fetcher used for BOTH the search request and the
/// result-page fetches (bounded timeouts, plain UA, fail-soft). Reuses the
/// morning-briefing [DioSourceFetcher] so no new `dio` config is introduced.
/// Overridden with a fake in tests.
final webSearchFetcherProvider = Provider<SourceFetcher>((ref) => DioSourceFetcher());

/// Local-only persistence of the chosen search provider + SearXNG URL.
/// Overridden with a fake in tests.
final webSearchPreferencesProvider =
    Provider<WebSearchPreferences>((ref) => SharedPrefsWebSearchPreferences());

/// The user's persisted web-search configuration ([WebSearchProvider] + the
/// SearXNG base URL). Hydrates asynchronously from [webSearchPreferencesProvider]
/// without blocking first read; defaults to DuckDuckGo (the zero-config option)
/// until persistence resolves.
final webSearchSettingsProvider =
    NotifierProvider<WebSearchSettingsNotifier, WebSearchSettings>(WebSearchSettingsNotifier.new);

class WebSearchSettingsNotifier extends Notifier<WebSearchSettings> {
  Future<void>? _hydration;

  /// Lets tests await the initial hydration deterministically.
  Future<void> get ready => _hydration ?? Future<void>.value();

  @override
  WebSearchSettings build() {
    _hydration = _hydrate();
    return const WebSearchSettings();
  }

  Future<void> _hydrate() async {
    try {
      state = await ref.read(webSearchPreferencesProvider).load();
    } catch (_) {
      // Persistence unavailable (e.g. no platform channel in a widget test) —
      // stay at the safe DuckDuckGo default rather than crashing.
    }
  }

  /// Sets the active provider and persists it. Selecting [WebSearchProvider.none]
  /// also forces the chat "buscar en internet" toggle OFF so no stale-enabled
  /// state can trigger a search once the globe button is hidden.
  Future<void> setProvider(WebSearchProvider provider) async {
    if (provider == WebSearchProvider.none) {
      ref.read(webSearchEnabledProvider.notifier).set(false);
    }
    await _update(state.copyWith(provider: provider));
  }

  /// Sets the SearXNG base URL and persists it.
  Future<void> setSearxngBaseUrl(String url) => _update(state.copyWith(searxngBaseUrl: url.trim()));

  Future<void> _update(WebSearchSettings next) async {
    state = next;
    try {
      await ref.read(webSearchPreferencesProvider).save(next);
    } catch (_) {
      // Best-effort persistence; in-memory state still reflects the choice.
    }
  }
}

/// The active [WebSearchBackend] for the current provider preference:
/// DuckDuckGo → the public DDG-lite scrape; SearXNG → the user's own instance
/// (saved URL); None → a no-op backend that returns zero results (search is also
/// gated off upstream, so this is just a safe terminal). Rebuilds when the
/// settings change. Overridden with a fake in tests.
final webSearchBackendProvider = Provider<WebSearchBackend>((ref) {
  final settings = ref.watch(webSearchSettingsProvider);
  final fetcher = ref.watch(webSearchFetcherProvider);
  switch (settings.provider) {
    case WebSearchProvider.duckduckgo:
      return DuckDuckGoBackend(fetcher: fetcher);
    case WebSearchProvider.searxng:
      return SearxngBackend(fetcher: fetcher, baseUrl: settings.searxngBaseUrl);
    case WebSearchProvider.none:
      return const _DisabledSearchBackend();
  }
});

/// Terminal no-op backend for [WebSearchProvider.none]: always zero results, so
/// the pipeline fails soft even if it is ever reached (it normally is not — the
/// chat toggle is hidden + forced off for "none").
class _DisabledSearchBackend implements WebSearchBackend {
  const _DisabledSearchBackend();

  @override
  Future<List<DdgResult>> search(String query) async => const [];
}

/// The on-device web-search pipeline (backend → fetch → extract → context +
/// sources). Uses the user-selected [webSearchBackendProvider]. Long-lived;
/// overridden with a fake in tests.
final webSearchPipelineProvider = Provider<WebSearchPipeline>((ref) {
  final fetcher = ref.watch(webSearchFetcherProvider);
  return WebSearchPipeline(
    search: ref.watch(webSearchBackendProvider),
    fetcher: fetcher,
  );
});
