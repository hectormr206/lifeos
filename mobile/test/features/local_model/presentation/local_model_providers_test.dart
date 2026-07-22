// Proves the local-model toggle provider + repository selection (roadmap
// SLICE 1): the toggle defaults off, hydrates from persistence, persists on
// write; and chatRepositoryProvider swaps to the on-device repository when the
// toggle is on. Uses fakes for both the engine and the persistence — no
// flutter_gemma, no shared_preferences channel.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/api/api_providers.dart';
import 'package:lifeos/features/chat/data/chat_repository.dart';
import 'package:lifeos/features/chat/presentation/chat_notifier.dart';
import 'package:lifeos/features/local_model/data/on_device_chat_repository.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/local_model_preferences.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import '../../../support/fake_token_store.dart';
import '../support/fake_local_llm_engine.dart';

ProviderContainer _container({
  required LocalModelPreferences prefs,
  LocalLlmEngine? engine,
}) {
  final container = ProviderContainer(overrides: [
    localModelPreferencesProvider.overrideWithValue(prefs),
    localLlmEngineProvider.overrideWithValue(engine ?? FakeLocalLlmEngine()),
    tokenStoreProvider.overrideWithValue(FakeTokenStore()),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('localModelEnabledProvider defaults to false', () {
    final container = _container(prefs: FakeLocalModelPreferences(enabled: false));
    expect(container.read(localModelEnabledProvider), isFalse);
  });

  test('hydrates the toggle from persistence after build', () async {
    final container = _container(prefs: FakeLocalModelPreferences(enabled: true));
    // Synchronous default first…
    expect(container.read(localModelEnabledProvider), isFalse);
    // …then flips once the async load resolves.
    await container.read(localModelEnabledProvider.notifier).unawaitedLoad();
    expect(container.read(localModelEnabledProvider), isTrue);
  });

  test('setEnabled updates state and persists', () async {
    final prefs = FakeLocalModelPreferences();
    final container = _container(prefs: prefs);

    await container.read(localModelEnabledProvider.notifier).setEnabled(true);

    expect(container.read(localModelEnabledProvider), isTrue);
    expect(prefs.writes, 1);
  });

  test('chatRepositoryProvider is HttpChatRepository when the toggle is off', () {
    final container = _container(prefs: FakeLocalModelPreferences(enabled: false));
    expect(container.read(chatRepositoryProvider), isA<HttpChatRepository>());
  });

  test('chatRepositoryProvider swaps to OnDeviceChatRepository when the toggle flips on', () async {
    final container = _container(prefs: FakeLocalModelPreferences());
    expect(container.read(chatRepositoryProvider), isA<HttpChatRepository>());

    await container.read(localModelEnabledProvider.notifier).setEnabled(true);

    expect(container.read(chatRepositoryProvider), isA<OnDeviceChatRepository>());
  });
}
