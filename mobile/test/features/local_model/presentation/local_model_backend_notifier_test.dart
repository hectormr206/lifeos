// Proves the developer "forzar backend" setting actually reaches the engine.
//
// Two things have to be true for an on-device GPU-vs-CPU benchmark to mean
// anything: the choice must land in `LocalModelConfig.backend` (the only value
// `FlutterGemmaLlmEngine.load()` falls back to when a caller passes no
// backend), and flipping it must RELEASE the resident model — the engine keeps
// its native handle and `load()` returns early while one is loaded, so without
// the unload the next generation would still run on the old backend and the
// measurement would be a lie.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/local_model_backend_preference.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import '../support/fake_local_llm_engine.dart';

/// In-memory [LocalModelBackendPreference] — no shared_preferences channel.
class FakeLocalModelBackendPreference implements LocalModelBackendPreference {
  FakeLocalModelBackendPreference([this.stored]);

  LocalLlmBackend? stored;
  int writes = 0;

  @override
  Future<LocalLlmBackend?> forcedBackend() async => stored;

  @override
  Future<void> setForcedBackend(LocalLlmBackend? backend) async {
    writes++;
    stored = backend;
  }
}

void main() {
  late FakeLocalModelBackendPreference prefs;
  late FakeLocalLlmEngine engine;

  ProviderContainer containerWith(LocalLlmBackend? stored) {
    prefs = FakeLocalModelBackendPreference(stored);
    engine = FakeLocalLlmEngine(installed: true);
    final container = ProviderContainer(overrides: [
      localModelBackendPreferenceProvider.overrideWithValue(prefs),
      localLlmEngineProvider.overrideWithValue(engine),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('with nothing stored the config keeps the automatic (GPU-first) backend',
      () async {
    final container = containerWith(null);
    await container.read(forcedLocalModelBackendProvider.notifier).hydrated;

    expect(container.read(forcedLocalModelBackendProvider), isNull);
    expect(
      container.read(localModelConfigProvider).backend,
      const LocalModelConfig().backend,
    );
  });

  test('a stored forced backend hydrates into the config', () async {
    final container = containerWith(LocalLlmBackend.cpu);
    await container.read(forcedLocalModelBackendProvider.notifier).hydrated;

    expect(container.read(forcedLocalModelBackendProvider), LocalLlmBackend.cpu);
    expect(container.read(localModelConfigProvider).backend, LocalLlmBackend.cpu);
  });

  test('choosing a backend persists it and rewrites the config', () async {
    final container = containerWith(null);
    final notifier = container.read(forcedLocalModelBackendProvider.notifier);
    await notifier.hydrated;

    await notifier.setForcedBackend(LocalLlmBackend.cpu);

    expect(prefs.stored, LocalLlmBackend.cpu);
    expect(container.read(localModelConfigProvider).backend, LocalLlmBackend.cpu);
  });

  test('going back to automatic clears the stored choice', () async {
    final container = containerWith(LocalLlmBackend.cpu);
    final notifier = container.read(forcedLocalModelBackendProvider.notifier);
    await notifier.hydrated;

    await notifier.setForcedBackend(null);

    expect(prefs.stored, isNull);
    expect(
      container.read(localModelConfigProvider).backend,
      const LocalModelConfig().backend,
    );
  });

  test('changing the backend RELEASES the resident model', () async {
    final container = containerWith(null);
    final notifier = container.read(forcedLocalModelBackendProvider.notifier);
    await notifier.hydrated;
    await engine.load();
    expect(engine.disposeCount, 0);

    await notifier.setForcedBackend(LocalLlmBackend.cpu);

    expect(engine.disposeCount, 1);
  });

  test('re-picking the SAME backend neither writes nor unloads', () async {
    final container = containerWith(LocalLlmBackend.cpu);
    final notifier = container.read(forcedLocalModelBackendProvider.notifier);
    await notifier.hydrated;
    prefs.writes = 0;

    await notifier.setForcedBackend(LocalLlmBackend.cpu);

    expect(prefs.writes, 0);
    expect(engine.disposeCount, 0);
  });
}
