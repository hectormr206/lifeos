// Proves the per-voice downloader group that fixes the concurrent-download
// deadlock: each voice's tasks live in their OWN group, so the defensive
// `reset(group:)` at the start of one download can never cancel a sibling
// voice that is downloading at the same time. Pure string derivation — no
// platform channels, no network. Plus the espeak idempotency guard: a
// redundant archive (concurrent sibling extracted first) is RECLAIMED, not
// leaked.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/data/background_downloader_tts_voice_gateway.dart';

void main() {
  group('BackgroundDownloaderTtsVoiceGateway.groupForVoice', () {
    test('is stable for a given voice id', () {
      expect(
        BackgroundDownloaderTtsVoiceGateway.groupForVoice('es_MX-claude'),
        BackgroundDownloaderTtsVoiceGateway.groupForVoice('es_MX-claude'),
      );
    });

    test('differs between voices so one reset never hits another', () {
      final a = BackgroundDownloaderTtsVoiceGateway.groupForVoice('es_MX-claude');
      final b = BackgroundDownloaderTtsVoiceGateway.groupForVoice('en_US-lessac');
      final c = BackgroundDownloaderTtsVoiceGateway.groupForVoice('es_MX-ald');
      expect({a, b, c}, hasLength(3));
    });

    test('sanitizes id chars into a valid identifier group', () {
      final group = BackgroundDownloaderTtsVoiceGateway.groupForVoice('en_GB-jenny_dioco');
      expect(group, matches(RegExp(r'^[A-Za-z0-9_]+$')));
      expect(group, startsWith('tts_voice_'));
    });
  });

  group('reclaimRedundantEspeakArchive (idempotency guard)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('espeak_reclaim_test');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('marker present → skip extraction AND delete the redundant archive', () async {
      // Regression: the early-return sat BEFORE the archive-deletion step, so
      // the second concurrent voice download leaked its multi-MB archive
      // forever (needsEspeak is false from then on — nothing else deletes it).
      final marker = File('${tmp.path}/phontab')..writeAsStringSync('x');
      final archive = File('${tmp.path}/espeak-ng-data.tar.gz')
        ..writeAsBytesSync(List.filled(64, 1));

      final skipped =
          await BackgroundDownloaderTtsVoiceGateway.reclaimRedundantEspeakArchive(
        markerPath: marker.path,
        archivePath: archive.path,
      );

      expect(skipped, isTrue);
      expect(archive.existsSync(), isFalse, reason: 'the archive is reclaimed');
    });

    test('marker absent → extraction proceeds and the archive is kept', () async {
      final archive = File('${tmp.path}/espeak-ng-data.tar.gz')
        ..writeAsBytesSync(List.filled(64, 1));

      final skipped =
          await BackgroundDownloaderTtsVoiceGateway.reclaimRedundantEspeakArchive(
        markerPath: '${tmp.path}/phontab',
        archivePath: archive.path,
      );

      expect(skipped, isFalse);
      expect(archive.existsSync(), isTrue,
          reason: 'the extractor still needs the archive');
    });
  });
}
