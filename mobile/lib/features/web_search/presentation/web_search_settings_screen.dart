import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../data/searxng_backend.dart';
import '../domain/web_search_settings.dart';
import 'web_search_providers.dart';

/// Settings → "Búsqueda web": pick the web-search provider used by the chat's
/// globe toggle. Three options — public DuckDuckGo (default, zero-config), the
/// user's own SearXNG instance (private), or none (search off). When SearXNG is
/// chosen, a URL field + a "Probar conexión" button let the user verify their
/// instance answers before relying on it.
///
/// Offline-reachable / not pairing-gated: everything here is a local preference.
class WebSearchSettingsScreen extends ConsumerStatefulWidget {
  const WebSearchSettingsScreen({super.key});

  @override
  ConsumerState<WebSearchSettingsScreen> createState() => _WebSearchSettingsScreenState();
}

/// The outcome of a "Probar conexión" run, driving the inline status line.
enum _TestState { idle, running, success, failure }

class _WebSearchSettingsScreenState extends ConsumerState<WebSearchSettingsScreen> {
  final TextEditingController _urlController = TextEditingController();
  _TestState _testState = _TestState.idle;
  bool _urlHydrated = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final settings = ref.watch(webSearchSettingsProvider);
    // Seed the field from the persisted URL once (after async hydration), then
    // let the user edit freely without the watch clobbering their typing.
    if (!_urlHydrated && settings.searxngBaseUrl.isNotEmpty) {
      _urlController.text = settings.searxngBaseUrl;
      _urlHydrated = true;
    }

    return Scaffold(
      appBar: AppBar(title: Text(l10n.webSearchSettingsTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(l10n.webSearchSettingsIntro,
                style: Theme.of(context).textTheme.bodyMedium),
          ),
          RadioGroup<WebSearchProvider>(
            groupValue: settings.provider,
            onChanged: _selectProvider,
            child: Column(
              children: [
                _ProviderOption(
                  value: WebSearchProvider.duckduckgo,
                  title: l10n.webSearchProviderDuckduckgo,
                  subtitle: l10n.webSearchProviderDuckduckgoDesc,
                ),
                _ProviderOption(
                  value: WebSearchProvider.searxng,
                  title: l10n.webSearchProviderSearxng,
                  subtitle: l10n.webSearchProviderSearxngDesc,
                ),
                if (settings.provider == WebSearchProvider.searxng) _buildSearxngConfig(l10n),
                _ProviderOption(
                  value: WebSearchProvider.none,
                  title: l10n.webSearchProviderNone,
                  subtitle: l10n.webSearchProviderNoneDesc,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearxngConfig(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: l10n.webSearchSearxngUrlLabel,
              hintText: 'https://searx.ejemplo.com',
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) {
              ref.read(webSearchSettingsProvider.notifier).setSearxngBaseUrl(value);
              if (_testState != _TestState.idle) setState(() => _testState = _TestState.idle);
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _testState == _TestState.running ? null : _testConnection,
                icon: _testState == _TestState.running
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering),
                label: Text(l10n.webSearchTestConnection),
              ),
              const SizedBox(width: 12),
              Expanded(child: _buildTestStatus(l10n)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTestStatus(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    switch (_testState) {
      case _TestState.idle:
        return const SizedBox.shrink();
      case _TestState.running:
        return Text(l10n.webSearchTesting, style: TextStyle(color: scheme.onSurfaceVariant));
      case _TestState.success:
        return Row(children: [
          Icon(Icons.check_circle, color: scheme.primary, size: 18),
          const SizedBox(width: 4),
          Expanded(child: Text(l10n.webSearchTestSuccess, style: TextStyle(color: scheme.primary))),
        ]);
      case _TestState.failure:
        return Row(children: [
          Icon(Icons.error_outline, color: scheme.error, size: 18),
          const SizedBox(width: 4),
          Expanded(child: Text(l10n.webSearchTestFailure, style: TextStyle(color: scheme.error))),
        ]);
    }
  }

  void _selectProvider(WebSearchProvider? provider) {
    if (provider == null) return;
    ref.read(webSearchSettingsProvider.notifier).setProvider(provider);
    if (_testState != _TestState.idle) setState(() => _testState = _TestState.idle);
  }

  /// Runs a throwaway search against the ENTERED URL and reports whether the
  /// instance answered with usable results. Uses the overridable fetcher, so
  /// tests can inject a fake without any network.
  Future<void> _testConnection() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _testState = _TestState.failure);
      return;
    }
    setState(() => _testState = _TestState.running);
    final backend = SearxngBackend(
      fetcher: ref.read(webSearchFetcherProvider),
      baseUrl: url,
    );
    var ok = false;
    try {
      final results = await backend.search('lifeos ping');
      ok = results.isNotEmpty;
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() => _testState = ok ? _TestState.success : _TestState.failure);
  }
}

/// One selectable provider row: a radio + a title/description. The selected
/// value + change handler come from the enclosing [RadioGroup] ancestor.
/// Tapping anywhere on the tile selects it.
class _ProviderOption extends StatelessWidget {
  const _ProviderOption({
    required this.value,
    required this.title,
    required this.subtitle,
  });

  final WebSearchProvider value;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return RadioListTile<WebSearchProvider>(
      value: value,
      title: Text(title),
      subtitle: Text(subtitle),
      controlAffinity: ListTileControlAffinity.leading,
    );
  }
}
