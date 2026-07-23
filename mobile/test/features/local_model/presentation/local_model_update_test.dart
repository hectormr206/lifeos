// Proves the brain-model OTA orchestration in LocalModelManagerNotifier:
// manifest-vs-tracked comparison → updateAvailable, adopt-in-place migration
// (an installed model with no tracked version becomes versionCode 1 with NO
// re-download), the user-tapped update flow (gateway download → verified path
// handed to installModelFromFile → version tracked → banner gone), a
// verification failure rejecting the update, and delete removing the OTA file
// + clearing the tracked version. All with in-memory fakes — no network, no
// filesystem, no 2.6GB.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/brain_model_manifest.dart';
import 'package:lifeos/features/local_model/domain/brain_model_version_store.dart';
import 'package:lifeos/features/local_model/presentation/local_model_notifier.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import '../support/fake_brain_model_ota.dart';
import '../support/fake_local_llm_engine.dart';

ProviderContainer _container({
  required FakeLocalLlmEngine engine,
  required FakeBrainModelUpdateGateway gateway,
  required FakeBrainModelVersionStore store,
}) {
  final container = ProviderContainer(overrides: [
    localLlmEngineProvider.overrideWithValue(engine),
    notificationPermissionGatewayProvider.overrideWithValue(FakeNotificationPermissionGateway()),
    brainModelUpdateGatewayProvider.overrideWithValue(gateway),
    brainModelVersionStoreProvider.overrideWithValue(store),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('update-available comparison', () {
    test('server versionCode > installed → updateAvailable', () async {
      final container = _container(
        engine: FakeLocalLlmEngine(installed: true),
        gateway: FakeBrainModelUpdateGateway(manifest: brainManifest(versionCode: 2)),
        store: FakeBrainModelVersionStore(
          installed: const InstalledBrainModel(modelName: kBrainModelName, versionCode: 1),
        ),
      );
      final notifier = container.read(localModelManagerProvider.notifier);
      await notifier.ready;

      final state = container.read(localModelManagerProvider);
      expect(state.installedVersionCode, 1);
      expect(state.manifest?.versionCode, 2);
      expect(state.updateAvailable, isTrue);
    });

    test('server versionCode == installed → no update', () async {
      final container = _container(
        engine: FakeLocalLlmEngine(installed: true),
        gateway: FakeBrainModelUpdateGateway(manifest: brainManifest(versionCode: 1)),
        store: FakeBrainModelVersionStore(
          installed: const InstalledBrainModel(modelName: kBrainModelName, versionCode: 1),
        ),
      );
      await container.read(localModelManagerProvider.notifier).ready;
      expect(container.read(localModelManagerProvider).updateAvailable, isFalse);
    });

    test('fail-soft offline (null manifest) → no update, no error', () async {
      final container = _container(
        engine: FakeLocalLlmEngine(installed: true),
        gateway: FakeBrainModelUpdateGateway(manifest: null),
        store: FakeBrainModelVersionStore(
          installed: const InstalledBrainModel(modelName: kBrainModelName, versionCode: 1),
        ),
      );
      await container.read(localModelManagerProvider.notifier).ready;
      final state = container.read(localModelManagerProvider);
      expect(state.updateAvailable, isFalse);
      expect(state.error, isNull);
    });

    test('not installed → newer manifest is NOT an update (fresh-download case)', () async {
      final container = _container(
        engine: FakeLocalLlmEngine(installed: false),
        gateway: FakeBrainModelUpdateGateway(manifest: brainManifest(versionCode: 5)),
        store: FakeBrainModelVersionStore(),
      );
      await container.read(localModelManagerProvider.notifier).ready;
      expect(container.read(localModelManagerProvider).updateAvailable, isFalse);
    });
  });

  group('adopt-in-place migration', () {
    test('installed model with NO tracked version becomes versionCode 1, no re-download', () async {
      final gateway = FakeBrainModelUpdateGateway(manifest: null);
      final store = FakeBrainModelVersionStore(); // untracked (pre-OTA install)
      final container = _container(
        engine: FakeLocalLlmEngine(installed: true),
        gateway: gateway,
        store: store,
      );
      await container.read(localModelManagerProvider.notifier).ready;

      expect(
        store.value,
        const InstalledBrainModel(
          modelName: kBrainModelName,
          versionCode: kBrainModelAdoptedVersionCode,
        ),
        reason: 'the HF-era install is adopted as v1 in place',
      );
      expect(gateway.downloadCount, 0, reason: 'adoption must NEVER re-download 2.6GB');
      expect(container.read(localModelManagerProvider).installedVersionCode, 1);
    });

    test('adopted install + newer manifest → updateAvailable', () async {
      final container = _container(
        engine: FakeLocalLlmEngine(installed: true),
        gateway: FakeBrainModelUpdateGateway(manifest: brainManifest(versionCode: 2)),
        store: FakeBrainModelVersionStore(),
      );
      await container.read(localModelManagerProvider.notifier).ready;
      expect(container.read(localModelManagerProvider).updateAvailable, isTrue);
    });

    test('nothing installed → nothing is adopted', () async {
      final store = FakeBrainModelVersionStore();
      final container = _container(
        engine: FakeLocalLlmEngine(installed: false),
        gateway: FakeBrainModelUpdateGateway(manifest: null),
        store: store,
      );
      await container.read(localModelManagerProvider.notifier).ready;
      expect(store.value, isNull);
    });
  });

  group('OTA download / update flow', () {
    test('fresh install: gateway download → verified path → engine fromFile → tracked', () async {
      final engine = FakeLocalLlmEngine(installed: false);
      final gateway = FakeBrainModelUpdateGateway(manifest: brainManifest(versionCode: 2));
      final store = FakeBrainModelVersionStore();
      final container = _container(engine: engine, gateway: gateway, store: store);
      final notifier = container.read(localModelManagerProvider.notifier);
      await notifier.ready;

      await notifier.download();

      expect(gateway.downloadCount, 1);
      expect(engine.installedFromFilePaths, [gateway.downloadResultPath],
          reason: 'the engine must receive the VERIFIED local path (fromFile install)');
      expect(store.value?.versionCode, 2);
      final state = container.read(localModelManagerProvider);
      expect(state.installed, isTrue);
      expect(state.downloading, isFalse);
      expect(state.progress, 1.0);
      expect(state.error, isNull);
    });

    test('update: tap swaps to the new version and the banner condition clears', () async {
      final engine = FakeLocalLlmEngine(installed: true);
      final gateway = FakeBrainModelUpdateGateway(manifest: brainManifest(versionCode: 2));
      final store = FakeBrainModelVersionStore(
        installed: const InstalledBrainModel(modelName: kBrainModelName, versionCode: 1),
      );
      final container = _container(engine: engine, gateway: gateway, store: store);
      final notifier = container.read(localModelManagerProvider.notifier);
      await notifier.ready;
      expect(container.read(localModelManagerProvider).updateAvailable, isTrue);

      await notifier.download();

      final state = container.read(localModelManagerProvider);
      expect(state.installedVersionCode, 2);
      expect(state.updateAvailable, isFalse, reason: 'after the swap the banner must go away');
      expect(engine.installedFromFilePaths, hasLength(1));
      expect(store.value?.versionCode, 2);
    });

    test('sha256 verification failure REJECTS the update and surfaces an error', () async {
      final engine = FakeLocalLlmEngine(installed: true);
      final gateway = FakeBrainModelUpdateGateway(
        manifest: brainManifest(versionCode: 2),
        downloadShouldFailVerification: true,
      );
      final store = FakeBrainModelVersionStore(
        installed: const InstalledBrainModel(modelName: kBrainModelName, versionCode: 1),
      );
      final container = _container(engine: engine, gateway: gateway, store: store);
      final notifier = container.read(localModelManagerProvider.notifier);
      await notifier.ready;

      await notifier.download();

      final state = container.read(localModelManagerProvider);
      expect(state.error, isNotNull);
      expect(state.downloading, isFalse);
      expect(engine.installedFromFilePaths, isEmpty,
          reason: 'an unverified file must NEVER reach the engine');
      expect(store.value?.versionCode, 1, reason: 'the tracked version must not advance');
      expect(state.installed, isTrue, reason: 'the old model keeps working');
    });

    test('download progress from the gateway streams into state', () async {
      final gateway = FakeBrainModelUpdateGateway(
        manifest: brainManifest(),
        downloadProgress: const [0.2, 0.6],
      );
      final container = _container(
        engine: FakeLocalLlmEngine(),
        gateway: gateway,
        store: FakeBrainModelVersionStore(),
      );
      final notifier = container.read(localModelManagerProvider.notifier);
      await notifier.ready;

      await notifier.download();
      expect(container.read(localModelManagerProvider).progress, 1.0);
    });

    test('unconfigured source falls back to the legacy engine download, tracked as v1', () async {
      final engine = FakeLocalLlmEngine(installed: false);
      final gateway = FakeBrainModelUpdateGateway(configured: false);
      final store = FakeBrainModelVersionStore();
      final container = _container(engine: engine, gateway: gateway, store: store);
      final notifier = container.read(localModelManagerProvider.notifier);
      await notifier.ready;

      await notifier.download();

      expect(gateway.downloadCount, 0);
      expect(engine.installedFromFilePaths, isEmpty);
      final state = container.read(localModelManagerProvider);
      expect(state.installed, isTrue);
      expect(store.value?.versionCode, kBrainModelAdoptedVersionCode);
    });
  });

  group('delete', () {
    test('delete removes the OTA file and clears the tracked version', () async {
      final engine = FakeLocalLlmEngine(installed: true);
      final gateway = FakeBrainModelUpdateGateway(manifest: null);
      final store = FakeBrainModelVersionStore(
        installed: const InstalledBrainModel(modelName: kBrainModelName, versionCode: 2),
      );
      final container = _container(engine: engine, gateway: gateway, store: store);
      final notifier = container.read(localModelManagerProvider.notifier);
      await notifier.ready;

      await notifier.deleteModel();

      expect(engine.deleteCount, 1);
      expect(gateway.deleteLocalFileCount, 1,
          reason: 'flutter_gemma never deletes external fromFile installs — we must');
      expect(store.value, isNull);
      final state = container.read(localModelManagerProvider);
      expect(state.installed, isFalse);
      expect(state.installedVersionCode, isNull);
    });

    test('a failed engine delete leaves the file and the tracked version alone', () async {
      final engine = FakeLocalLlmEngine(installed: true, deleteShouldFail: true);
      final gateway = FakeBrainModelUpdateGateway(manifest: null);
      final store = FakeBrainModelVersionStore(
        installed: const InstalledBrainModel(modelName: kBrainModelName, versionCode: 2),
      );
      final container = _container(engine: engine, gateway: gateway, store: store);
      final notifier = container.read(localModelManagerProvider.notifier);
      await notifier.ready;

      await notifier.deleteModel();

      expect(gateway.deleteLocalFileCount, 0);
      expect(store.value?.versionCode, 2);
      expect(container.read(localModelManagerProvider).error, isNotNull);
    });
  });
}
