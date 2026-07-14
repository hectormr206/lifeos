// Proves Riverpod is actually wired (design D2), not just a dependency sitting
// unused in pubspec.yaml: overriding the base-URL provider and reading the
// repository provider through a [ProviderContainer] must produce a working
// [CapabilitiesRepository] backed by the generated [DefaultApi].
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/core/api/capabilities_repository.dart';

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
}
