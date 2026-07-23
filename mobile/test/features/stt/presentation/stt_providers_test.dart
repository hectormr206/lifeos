// Proves the STT model-download notifier: it hydrates Ready when the model is
// already on disk (else Absent), streams progress during a download and lands
// Ready, and surfaces a failed download as Failed (never throws to the UI).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';

import '../support/fake_stt.dart';

void main() {
  group('SttModelDownloadNotifier', () {
    test('hydrates to Ready when the model is already installed', () async {
      final gateway = FakeSttModelGateway(
        installed: const SttModelPaths(encoder: 'e', decoder: 'd', tokens: 't'),
      );
      final container = ProviderContainer(overrides: [
        sttModelGatewayProvider.overrideWithValue(gateway),
      ]);
      addTearDown(container.dispose);

      final notifier = container.read(sttModelDownloadProvider.notifier);
      await notifier.ready;

      expect(container.read(sttModelDownloadProvider), isA<SttModelReady>());
      expect(notifier.isReady, isTrue);
    });

    test('hydrates to Absent when the model is not installed', () async {
      final gateway = FakeSttModelGateway(installed: null);
      final container = ProviderContainer(overrides: [
        sttModelGatewayProvider.overrideWithValue(gateway),
      ]);
      addTearDown(container.dispose);

      final notifier = container.read(sttModelDownloadProvider.notifier);
      await notifier.ready;

      expect(container.read(sttModelDownloadProvider), isA<SttModelAbsent>());
    });

    test('download streams progress then lands Ready', () async {
      final gateway = FakeSttModelGateway(installed: null, downloadProgress: const [0.25, 0.75, 1.0]);
      final container = ProviderContainer(overrides: [
        sttModelGatewayProvider.overrideWithValue(gateway),
      ]);
      addTearDown(container.dispose);

      final notifier = container.read(sttModelDownloadProvider.notifier);
      await notifier.ready;

      await notifier.download();

      expect(gateway.downloadCalls, 1);
      expect(container.read(sttModelDownloadProvider), isA<SttModelReady>());
    });

    test('a failed download lands Failed, never throws', () async {
      final gateway = FakeSttModelGateway(installed: null, downloadError: Exception('boom'));
      final container = ProviderContainer(overrides: [
        sttModelGatewayProvider.overrideWithValue(gateway),
      ]);
      addTearDown(container.dispose);

      final notifier = container.read(sttModelDownloadProvider.notifier);
      await notifier.ready;

      await notifier.download(); // must not throw

      expect(container.read(sttModelDownloadProvider), isA<SttModelFailed>());
    });
  });
}
