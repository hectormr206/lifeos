// Proves LocalModelManagerNotifier (roadmap SLICE 1) drives the model-manager
// state off a FakeLocalLlmEngine: it probes installed state on build, streams
// download progress, marks installed on completion, and surfaces a failed
// download as an error — never touching a real download.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/presentation/local_model_notifier.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import '../support/fake_local_llm_engine.dart';

ProviderContainer _container(LocalLlmEngine engine) {
  final container = ProviderContainer(overrides: [
    localLlmEngineProvider.overrideWithValue(engine),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('probes installed=false on build', () async {
    final container = _container(FakeLocalLlmEngine(installed: false));
    await container.read(localModelManagerProvider.notifier).ready;
    final state = container.read(localModelManagerProvider);
    expect(state.checking, isFalse);
    expect(state.installed, isFalse);
  });

  test('probes installed=true on build', () async {
    final container = _container(FakeLocalLlmEngine(installed: true));
    await container.read(localModelManagerProvider.notifier).ready;
    expect(container.read(localModelManagerProvider).installed, isTrue);
  });

  test('download streams progress then marks installed', () async {
    final container = _container(FakeLocalLlmEngine(downloadProgress: const [0.3, 0.7, 1.0]));
    final notifier = container.read(localModelManagerProvider.notifier);
    await notifier.ready;

    await notifier.download();

    final state = container.read(localModelManagerProvider);
    expect(state.downloading, isFalse);
    expect(state.installed, isTrue);
    expect(state.progress, 1.0);
    expect(state.error, isNull);
  });

  test('download failure surfaces an error and clears downloading', () async {
    final container = _container(FakeLocalLlmEngine(downloadShouldFail: true));
    final notifier = container.read(localModelManagerProvider.notifier);
    await notifier.ready;

    await notifier.download();

    final state = container.read(localModelManagerProvider);
    expect(state.downloading, isFalse);
    expect(state.installed, isFalse);
    expect(state.error, isNotNull);
  });
}
