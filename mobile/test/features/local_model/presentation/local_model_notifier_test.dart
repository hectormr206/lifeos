// Proves LocalModelManagerNotifier (roadmap SLICE 1) drives the model-manager
// state off a FakeLocalLlmEngine: it probes installed state on build, streams
// download progress, marks installed on completion, and surfaces a failed
// download as an error — never touching a real download.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';
import 'package:lifeos/features/local_model/domain/notification_permission.dart';
import 'package:lifeos/features/local_model/presentation/local_model_notifier.dart';
import 'package:lifeos/features/local_model/presentation/local_model_providers.dart';

import '../support/fake_local_llm_engine.dart';

ProviderContainer _container(
  LocalLlmEngine engine, {
  FakeNotificationPermissionGateway? gateway,
}) {
  final container = ProviderContainer(overrides: [
    localLlmEngineProvider.overrideWithValue(engine),
    notificationPermissionGatewayProvider
        .overrideWithValue(gateway ?? FakeNotificationPermissionGateway()),
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

  test('download requests the notification permission and records granted', () async {
    final gateway = FakeNotificationPermissionGateway(requestResult: NotificationPermission.granted);
    final container = _container(FakeLocalLlmEngine(), gateway: gateway);
    final notifier = container.read(localModelManagerProvider.notifier);
    await notifier.ready;

    await notifier.download();

    expect(gateway.requestCount, 1);
    final state = container.read(localModelManagerProvider);
    expect(state.notificationPermission, NotificationPermission.granted);
    expect(state.installed, isTrue);
  });

  test('download still installs when notifications are DENIED (not required)', () async {
    // Empirical finding: the download completes without POST_NOTIFICATIONS — a
    // denial must never block it.
    final gateway = FakeNotificationPermissionGateway(requestResult: NotificationPermission.denied);
    final container = _container(
      FakeLocalLlmEngine(downloadProgress: const [0.5, 1.0]),
      gateway: gateway,
    );
    final notifier = container.read(localModelManagerProvider.notifier);
    await notifier.ready;

    await notifier.download();

    final state = container.read(localModelManagerProvider);
    expect(state.notificationPermission, NotificationPermission.denied);
    expect(state.installed, isTrue, reason: 'denied notifications must not block the download');
    expect(state.error, isNull);
  });

  test('re-tapping download re-requests the notification permission', () async {
    final gateway = FakeNotificationPermissionGateway(requestResult: NotificationPermission.denied);
    final container = _container(
      FakeLocalLlmEngine(downloadShouldFail: true),
      gateway: gateway,
    );
    final notifier = container.read(localModelManagerProvider.notifier);
    await notifier.ready;

    await notifier.download(); // first (soft) denial
    gateway.requestResult = NotificationPermission.granted; // user relents
    await notifier.download(); // retry re-requests

    expect(gateway.requestCount, 2);
    expect(container.read(localModelManagerProvider).notificationPermission,
        NotificationPermission.granted);
  });

  test('deleteModel flips installed→false and clears deleting', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    final container = _container(engine);
    final notifier = container.read(localModelManagerProvider.notifier);
    await notifier.ready;
    expect(container.read(localModelManagerProvider).installed, isTrue);

    await notifier.deleteModel();

    final state = container.read(localModelManagerProvider);
    expect(state.installed, isFalse);
    expect(state.deleting, isFalse);
    expect(state.error, isNull);
    expect(engine.deleteCount, 1);
  });

  test('deleteModel failure surfaces an error and keeps installed', () async {
    final engine = FakeLocalLlmEngine(installed: true, deleteShouldFail: true);
    final container = _container(engine);
    final notifier = container.read(localModelManagerProvider.notifier);
    await notifier.ready;

    await notifier.deleteModel();

    final state = container.read(localModelManagerProvider);
    expect(state.deleting, isFalse);
    expect(state.installed, isTrue, reason: 'a failed delete leaves the weights in place');
    expect(state.error, isNotNull);
  });

  test('after deleteModel the local-mode toggle can no longer be on (gating)', () async {
    final engine = FakeLocalLlmEngine(installed: true);
    final container = ProviderContainer(overrides: [
      localLlmEngineProvider.overrideWithValue(engine),
      notificationPermissionGatewayProvider
          .overrideWithValue(FakeNotificationPermissionGateway()),
    ]);
    addTearDown(container.dispose);

    // Enable local mode (allowed because the model is installed).
    await container.read(localModelEnabledProvider.notifier).setEnabled(true);
    expect(container.read(localModelEnabledProvider), isTrue);

    final notifier = container.read(localModelManagerProvider.notifier);
    await notifier.ready;
    await notifier.deleteModel();

    // With the weights gone, local mode is forced back OFF.
    expect(container.read(localModelEnabledProvider), isFalse);
  });

  test('permanently denied is recorded and openNotificationSettings deep-links', () async {
    final gateway =
        FakeNotificationPermissionGateway(requestResult: NotificationPermission.permanentlyDenied);
    final container = _container(FakeLocalLlmEngine(downloadShouldFail: true), gateway: gateway);
    final notifier = container.read(localModelManagerProvider.notifier);
    await notifier.ready;

    await notifier.download();
    expect(container.read(localModelManagerProvider).notificationPermission,
        NotificationPermission.permanentlyDenied);

    await notifier.openNotificationSettings();
    expect(gateway.openSettingsCount, 1);
  });
}
