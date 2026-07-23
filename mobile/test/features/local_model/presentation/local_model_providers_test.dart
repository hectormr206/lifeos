// Proves the on-device mode provider + repository selection. LifeOS is now
// on-device-first: local mode is ALWAYS ON (there is no user toggle), so
// `localModelEnabledProvider` reports `true` and `chatRepositoryProvider`
// always serves the on-device repository. Uses fakes for the engine and the
// persistence — no flutter_gemma, no shared_preferences channel.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/local_model/data/on_device_chat_repository.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import '../../../support/fake_token_store.dart';
import '../support/fake_local_llm_engine.dart';

ProviderContainer _container({LocalLlmEngine? engine}) {
  final container = ProviderContainer(overrides: [
    localLlmEngineProvider.overrideWithValue(engine ?? FakeLocalLlmEngine(installed: true)),
    tokenStoreProvider.overrideWithValue(FakeTokenStore()),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('localModelEnabledProvider is always ON (on-device-first, no toggle)', () {
    final container = _container();
    expect(container.read(localModelEnabledProvider), isTrue);
  });

  test('chatRepositoryProvider serves the on-device repository', () {
    final container = _container(engine: FakeLocalLlmEngine(installed: true));
    expect(container.read(chatRepositoryProvider), isA<OnDeviceChatRepository>());
  });
}
