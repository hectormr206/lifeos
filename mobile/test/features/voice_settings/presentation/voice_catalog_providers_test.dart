// Proves the voice-selection notifier and the catalog controller:
//  * selection defaults to es_MX-claude, hydrates a stored pick, and persists;
//  * selecting a NOT-installed voice triggers its download, an installed one
//    does not;
//  * the controller detects installed voices (both files present) as Ready and
//    the rest as Absent, streams download progress, and never throws on failure.
// All engine/persistence/network seams are faked (no platform channels).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/domain/tts_voice.dart';
import 'package:lifeos/features/tts/presentation/tts_providers.dart';
import 'package:lifeos/features/voice_settings/domain/selected_voice.dart';
import 'package:lifeos/features/voice_settings/domain/voice_catalog.dart';
import 'package:lifeos/features/voice_settings/presentation/voice_catalog_providers.dart';

import '../../tts/support/fake_tts.dart';

/// In-memory [SelectedVoicePreferences] recording the last saved id.
class FakeSelectedVoicePreferences implements SelectedVoicePreferences {
  FakeSelectedVoicePreferences({String? initial}) : _stored = initial;

  String? _stored;
  int writes = 0;

  String? get stored => _stored;

  @override
  Future<String?> load() async => _stored;

  @override
  Future<void> save(String voiceId) async {
    _stored = voiceId;
    writes++;
  }
}

const _paths = TtsVoicePaths(model: 'm.onnx', tokens: 'm.tokens.txt', dataDir: 'espeak');

ProviderContainer _container({
  required FakeTtsVoiceGateway gateway,
  FakeSelectedVoicePreferences? prefs,
}) {
  final container = ProviderContainer(overrides: [
    ttsVoiceGatewayProvider.overrideWithValue(gateway),
    selectedVoicePreferencesProvider.overrideWithValue(prefs ?? FakeSelectedVoicePreferences()),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('selectedVoiceProvider', () {
    test('defaults to es_MX-claude when nothing is stored', () async {
      final container = _container(gateway: FakeTtsVoiceGateway());
      final notifier = container.read(selectedVoiceProvider.notifier);
      await notifier.ready;

      expect(container.read(selectedVoiceProvider), 'es_MX-claude');
    });

    test('hydrates a stored pick', () async {
      final container = _container(
        gateway: FakeTtsVoiceGateway(),
        prefs: FakeSelectedVoicePreferences(initial: 'es_ES-davefx'),
      );
      final notifier = container.read(selectedVoiceProvider.notifier);
      await notifier.ready;

      expect(container.read(selectedVoiceProvider), 'es_ES-davefx');
    });

    test('ignores a stored id that is no longer in the catalog', () async {
      final container = _container(
        gateway: FakeTtsVoiceGateway(),
        prefs: FakeSelectedVoicePreferences(initial: 'legacy-voice'),
      );
      final notifier = container.read(selectedVoiceProvider.notifier);
      await notifier.ready;

      expect(container.read(selectedVoiceProvider), 'es_MX-claude');
    });

    test('select persists the pick and updates state', () async {
      final prefs = FakeSelectedVoicePreferences();
      final gateway = FakeTtsVoiceGateway(installed: {'en_US-lessac': _paths});
      final container = _container(gateway: gateway, prefs: prefs);
      final notifier = container.read(selectedVoiceProvider.notifier);
      await notifier.ready;

      await notifier.select('en_US-lessac');

      expect(container.read(selectedVoiceProvider), 'en_US-lessac');
      expect(prefs.stored, 'en_US-lessac');
      expect(prefs.writes, greaterThan(0));
    });

    test('selecting a not-yet-installed voice triggers its download', () async {
      final gateway = FakeTtsVoiceGateway(); // nothing installed
      final container = _container(gateway: gateway);
      final notifier = container.read(selectedVoiceProvider.notifier);
      await notifier.ready;

      await notifier.select('es_AR-daniela');

      expect(gateway.downloadCalls, contains('es_AR-daniela'));
    });

    test('selecting an already-installed voice does NOT download', () async {
      final gateway = FakeTtsVoiceGateway(installed: {'es_MX-ald': _paths});
      final container = _container(gateway: gateway);
      final notifier = container.read(selectedVoiceProvider.notifier);
      await notifier.ready;

      await notifier.select('es_MX-ald');

      expect(gateway.downloadCalls, isEmpty);
    });

    test('ignores an unknown voice id', () async {
      final gateway = FakeTtsVoiceGateway();
      final container = _container(gateway: gateway);
      final notifier = container.read(selectedVoiceProvider.notifier);
      await notifier.ready;

      await notifier.select('not-a-voice');

      expect(container.read(selectedVoiceProvider), 'es_MX-claude');
      expect(gateway.downloadCalls, isEmpty);
    });
  });

  group('voiceCatalogControllerProvider', () {
    test('detects installed voices (both files present) as Ready, others Absent', () async {
      final gateway = FakeTtsVoiceGateway(installed: {'es_MX-claude': _paths});
      final container = _container(gateway: gateway);
      final notifier = container.read(voiceCatalogControllerProvider.notifier);
      await notifier.ready;

      final statuses = container.read(voiceCatalogControllerProvider);
      expect(statuses['es_MX-claude'], isA<TtsVoiceReady>());
      expect(statuses['es_MX-ald'], isA<TtsVoiceAbsent>());
      expect(statuses['en_GB-alan'], isA<TtsVoiceAbsent>());
    });

    test('download streams progress then lands Ready', () async {
      final gateway = FakeTtsVoiceGateway(downloadProgress: const [0.25, 0.75, 1.0]);
      final container = _container(gateway: gateway);
      final notifier = container.read(voiceCatalogControllerProvider.notifier);
      await notifier.ready;

      final seen = <TtsVoiceStatus>[];
      container.listen(
        voiceCatalogControllerProvider,
        (_, next) => seen.add(next['en_US-lessac'] ?? const TtsVoiceAbsent()),
      );

      await notifier.download('en_US-lessac');

      expect(gateway.downloadCalls, ['en_US-lessac']);
      expect(seen.whereType<TtsVoiceDownloading>(), isNotEmpty);
      expect(container.read(voiceCatalogControllerProvider)['en_US-lessac'], isA<TtsVoiceReady>());
    });

    test('an already-installed voice lands Ready WITHOUT downloading', () async {
      final gateway = FakeTtsVoiceGateway(installed: {'es_AR-daniela': _paths});
      final container = _container(gateway: gateway);
      final notifier = container.read(voiceCatalogControllerProvider.notifier);
      await notifier.ready;

      await notifier.download('es_AR-daniela');

      expect(gateway.downloadCalls, isEmpty);
      expect(container.read(voiceCatalogControllerProvider)['es_AR-daniela'], isA<TtsVoiceReady>());
    });

    test('a failed download lands Failed, never throws', () async {
      final gateway = FakeTtsVoiceGateway(downloadError: Exception('boom'));
      final container = _container(gateway: gateway);
      final notifier = container.read(voiceCatalogControllerProvider.notifier);
      await notifier.ready;

      await notifier.download('en_GB-alan'); // must not throw

      expect(container.read(voiceCatalogControllerProvider)['en_GB-alan'], isA<TtsVoiceFailed>());
    });

    test('concurrent downloads all complete — starting one never freezes another',
        () async {
      final gateway = FakeTtsVoiceGateway()..downloadGate = Completer<void>();
      final container = _container(gateway: gateway);
      final notifier = container.read(voiceCatalogControllerProvider.notifier);
      await notifier.ready;

      // Kick off three downloads WITHOUT awaiting the first before the next —
      // they are all in flight at once (the shared-group deadlock regression).
      final futures = [
        notifier.download('es_MX-claude'),
        notifier.download('en_US-lessac'),
        notifier.download('es_MX-ald'),
      ];
      // Let each download run up to the gate (past its async probe + progress).
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // All three parked at the gate, all Downloading, none cancelled.
      final mid = container.read(voiceCatalogControllerProvider);
      expect(mid['es_MX-claude'], isA<TtsVoiceDownloading>());
      expect(mid['en_US-lessac'], isA<TtsVoiceDownloading>());
      expect(mid['es_MX-ald'], isA<TtsVoiceDownloading>());

      gateway.downloadGate!.complete();
      await Future.wait(futures);

      final done = container.read(voiceCatalogControllerProvider);
      expect(done['es_MX-claude'], isA<TtsVoiceReady>());
      expect(done['en_US-lessac'], isA<TtsVoiceReady>());
      expect(done['es_MX-ald'], isA<TtsVoiceReady>());
      expect(gateway.downloadCalls, containsAll(['es_MX-claude', 'en_US-lessac', 'es_MX-ald']));
    });
  });

  group('VoiceCatalogController.delete', () {
    test('deletes a downloaded non-selected voice: removes files, marks Absent', () async {
      final gateway = FakeTtsVoiceGateway(installed: {
        'es_MX-claude': _paths,
        'en_US-lessac': _paths,
      });
      final container = _container(gateway: gateway);
      final controller = container.read(voiceCatalogControllerProvider.notifier);
      await controller.ready;
      await container.read(selectedVoiceProvider.notifier).ready; // stays es_MX-claude

      await controller.delete('en_US-lessac');

      expect(gateway.deleteCalls, ['en_US-lessac']);
      expect(gateway.installed.containsKey('en_US-lessac'), isFalse);
      expect(container.read(voiceCatalogControllerProvider)['en_US-lessac'], isA<TtsVoiceAbsent>());
      // Selection untouched, no download triggered.
      expect(container.read(selectedVoiceProvider), 'es_MX-claude');
      expect(gateway.downloadCalls, isEmpty);
    });

    test('deleting the SELECTED voice falls back to another installed voice, no redownload',
        () async {
      final prefs = FakeSelectedVoicePreferences(initial: 'es_MX-claude');
      final gateway = FakeTtsVoiceGateway(installed: {
        'es_MX-claude': _paths,
        'en_US-lessac': _paths,
      });
      final container = _container(gateway: gateway, prefs: prefs);
      final controller = container.read(voiceCatalogControllerProvider.notifier);
      await controller.ready;
      await container.read(selectedVoiceProvider.notifier).ready;

      await controller.delete('es_MX-claude');

      final selected = container.read(selectedVoiceProvider);
      expect(selected, 'en_US-lessac'); // fell back to the other installed voice
      expect(prefs.stored, 'en_US-lessac'); // persisted
      expect(gateway.downloadCalls, isEmpty); // NEVER re-download the deleted voice
    });

    test('deleting the SELECTED voice with none left falls back to the system voice',
        () async {
      final prefs = FakeSelectedVoicePreferences(initial: 'es_MX-claude');
      final gateway = FakeTtsVoiceGateway(installed: {'es_MX-claude': _paths});
      final container = _container(gateway: gateway, prefs: prefs);
      final controller = container.read(voiceCatalogControllerProvider.notifier);
      await controller.ready;
      await container.read(selectedVoiceProvider.notifier).ready;

      await controller.delete('es_MX-claude');

      expect(container.read(selectedVoiceProvider), VoiceCatalog.systemVoiceId);
      expect(prefs.stored, VoiceCatalog.systemVoiceId);
      expect(gateway.downloadCalls, isEmpty);
    });

    test('the system-voice selection sticks across launches (hydrates, no redownload)',
        () async {
      final gateway = FakeTtsVoiceGateway(); // nothing installed
      final container = _container(
        gateway: gateway,
        prefs: FakeSelectedVoicePreferences(initial: VoiceCatalog.systemVoiceId),
      );
      final notifier = container.read(selectedVoiceProvider.notifier);
      await notifier.ready;

      expect(container.read(selectedVoiceProvider), VoiceCatalog.systemVoiceId);
      expect(gateway.downloadCalls, isEmpty);
    });

    test('delete ignores an unknown voice id', () async {
      final gateway = FakeTtsVoiceGateway();
      final container = _container(gateway: gateway);
      final controller = container.read(voiceCatalogControllerProvider.notifier);
      await controller.ready;

      await controller.delete('not-a-voice');

      expect(gateway.deleteCalls, isEmpty);
    });
  });
}
