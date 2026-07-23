// Proves the on-device model load-state notifier: it stays idle in cloud/HTTP
// mode, warms the engine and transitions loading → ready in local mode,
// surfaces a neutral-Spanish error on failure, and recovers via retry(). This
// is what drives the chat's "Cargando el modelo…" banner + send gating.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/presentation/local_model_load_notifier.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import '../support/fake_local_llm_engine.dart';

/// Forces [localModelEnabledProvider] to a fixed value without the async
/// shared_preferences hydration, so the loader's local/cloud branch is
/// deterministic in tests.
class _FixedEnabledNotifier extends LocalModelEnabledNotifier {
  _FixedEnabledNotifier(this._value);

  final bool _value;

  @override
  bool build() => _value;
}

ProviderContainer _container(FakeLocalLlmEngine engine, {required bool enabled}) {
  final container = ProviderContainer(
    overrides: [
      localLlmEngineProvider.overrideWithValue(engine),
      localModelEnabledProvider.overrideWith(() => _FixedEnabledNotifier(enabled)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('stays idle and never touches the engine in cloud/HTTP mode', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    final container = _container(engine, enabled: false);

    final state = container.read(localModelLoadProvider);
    expect(state.status, LocalModelLoadStatus.idle);
    expect(state.isLoading, isFalse);

    await container.read(localModelLoadProvider.notifier).ready;
    expect(engine.loadCount, 0, reason: 'no on-device model → nothing to load');
  });

  test('warms the engine and transitions loading → ready in local mode', () async {
    final gate = Completer<void>();
    final engine = FakeLocalLlmEngine(installed: true, loadGate: gate);
    final container = _container(engine, enabled: true);

    // First read: the load has been kicked off and is in flight.
    expect(container.read(localModelLoadProvider).status, LocalModelLoadStatus.loading);
    expect(engine.loadCount, 1);

    // Release the load → ready.
    gate.complete();
    await container.read(localModelLoadProvider.notifier).ready;
    expect(container.read(localModelLoadProvider).status, LocalModelLoadStatus.ready);
    expect(container.read(localModelLoadProvider).isReady, isTrue);
  });

  test('surfaces a neutral-Spanish error when the load fails', () async {
    final engine = FakeLocalLlmEngine(installed: true, loadShouldFail: true);
    final container = _container(engine, enabled: true);

    await container.read(localModelLoadProvider.notifier).ready;
    final state = container.read(localModelLoadProvider);
    expect(state.status, LocalModelLoadStatus.error);
    expect(state.hasError, isTrue);
    expect(state.error, contains('No se pudo cargar el modelo'));
  });

  test('retry() re-attempts a failed load and reaches ready when it succeeds', () async {
    final engine = FakeLocalLlmEngine(installed: true, loadShouldFail: true);
    final container = _container(engine, enabled: true);
    final notifier = container.read(localModelLoadProvider.notifier);

    await notifier.ready;
    expect(container.read(localModelLoadProvider).status, LocalModelLoadStatus.error);

    // The next attempt succeeds.
    engine.loadShouldFail = false;
    notifier.retry();
    expect(container.read(localModelLoadProvider).status, LocalModelLoadStatus.loading);

    await notifier.ready;
    expect(container.read(localModelLoadProvider).status, LocalModelLoadStatus.ready);
    expect(engine.loadCount, 2, reason: 'the failed load plus the retry');
  });

  test('retry() is a no-op while already ready', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    final container = _container(engine, enabled: true);
    final notifier = container.read(localModelLoadProvider.notifier);

    await notifier.ready;
    expect(container.read(localModelLoadProvider).status, LocalModelLoadStatus.ready);

    notifier.retry();
    expect(container.read(localModelLoadProvider).status, LocalModelLoadStatus.ready);
    expect(engine.loadCount, 1, reason: 'retry must not reload an already-ready model');
  });
}
