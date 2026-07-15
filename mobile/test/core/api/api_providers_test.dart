// Proves Riverpod is actually wired (design D2), not just a dependency sitting
// unused in pubspec.yaml: overriding the base-URL provider and reading the
// repository provider through a [ProviderContainer] must produce a working
// [CapabilitiesRepository] backed by the generated [DefaultApi].
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/api/capabilities_repository.dart';
import 'package:lifeos/core/tls/tls_trust_decision.dart';

void main() {
  test('capabilitiesRepositoryProvider resolves a repository configured with the overridden base URL', () {
    final container = ProviderContainer(
      overrides: [
        engineBaseUrlProvider.overrideWithValue('https://engine.example'),
      ],
    );
    addTearDown(container.dispose);

    final repository = container.read(capabilitiesRepositoryProvider);
    final dio = container.read(dioProvider);

    expect(repository, isA<CapabilitiesRepository>());
    expect(dio.options.baseUrl, 'https://engine.example');
  });

  // Connection-hardening batch (design D5/D6): dioProvider's adapter must
  // reflect the currently-active TLS trust decision, not just the base URL.
  group('dioProvider TLS wiring', () {
    test('leaves the default adapter untouched when no TLS trust decision is active', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final dio = container.read(dioProvider);

      expect(dio.httpClientAdapter, isA<IOHttpClientAdapter>());
    });

    test('rebuilds the adapter once activeTlsTrustProvider carries a pinned CA', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeTlsTrustProvider.notifier).state = const TlsTrustDecision(
        pinnedCaPem: '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----',
        host: 'engine.example',
      );

      final dio = container.read(dioProvider);

      // Rebuilding with a pin swaps in a *different* IOHttpClientAdapter
      // instance (a fresh createHttpClient closure), proving the trust
      // decision actually reached dio.httpClientAdapter.
      expect(dio.httpClientAdapter, isA<IOHttpClientAdapter>());
      expect((dio.httpClientAdapter as IOHttpClientAdapter).createHttpClient, isNotNull);
    });
  });
}
