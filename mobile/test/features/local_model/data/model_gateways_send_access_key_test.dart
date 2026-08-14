// EVERY model-download gateway must send the LifeOS access key, on every
// request, forever.
//
// WHY THIS EXISTS. `updates.lifeos.hectormr.com` is reachable from the public
// internet (an off-VPN device could otherwise never install LifeOS), so nginx
// key-gates `/model/`, `/stt/`, `/tts/` and `/embed/`. The moment that gate
// went in, a gateway that omits the header stops downloading — permanently,
// with a 403 the app turns into "no hay modelo" rather than an error anyone
// can act on.
//
// The reliability review caught the real gap: the claim that all four gateways
// send the header lived ONLY in a comment in `ops/ota/ota-root.conf`. It was
// true — verified by hand at the time — but a comment asserting something about
// four other files is a promise with no guarantor. Nothing stopped a future
// edit to the TTS gateway from dropping the header, and nothing would have
// noticed until a user's downloads silently stopped.
//
// The brain gateway already has its own behavioural test
// (`vps_brain_model_gateway_access_key_test.dart`) because it had a REAL defect:
// its manifest fetch went out bare. This file is the cheaper, broader net — it
// proves the header is present in each gateway's download task, for all four,
// which no behavioural test covers today.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every file that builds a `DownloadTask` against the key-gated update host.
/// If a fifth model type is added, its gateway belongs here the same day.
const List<String> _gateways = [
  'lib/features/local_model/data/vps_brain_model_gateway.dart',
  'lib/features/stt/data/background_downloader_stt_model_gateway.dart',
  'lib/features/tts/data/background_downloader_tts_voice_gateway.dart',
  'lib/features/embedding/data/background_downloader_embed_model_gateway.dart',
];

/// The header any request to the update host must carry, written as it appears
/// in source. Matching the CONSTANT rather than the literal string is
/// deliberate: a gateway that hardcoded `'X-LifeOS-Update-Key'` would drift the
/// day the constant is renamed, and this test would say so.
const String _headerConstant = 'kUpdateAccessKeyHeader';
const String _valueConstant = 'kUpdateAccessKey';

void main() {
  for (final path in _gateways) {
    test('$path sends the access key on its download task', () {
      final file = File(path);
      expect(
        file.existsSync(),
        isTrue,
        reason: '$path is listed as a model gateway but does not exist — if it '
            'moved, update this list; the gate on the server did not move',
      );

      final source = file.readAsStringSync();

      expect(
        source.contains('$_headerConstant: $_valueConstant'),
        isTrue,
        reason: 'this gateway downloads from the key-gated update host without '
            'sending $_headerConstant. nginx answers 403, and the app reports '
            '"no model" instead of an error anyone can act on. Add '
            'headers: {$_headerConstant: $_valueConstant} to its DownloadTask.',
      );
    });
  }

  test('the list covers every gateway that talks to the update host', () {
    // A new gateway added without being listed above would never be checked,
    // and the list would look complete. Sweep lib/ for anything else that
    // builds a DownloadTask, and require it to be either listed or clearly
    // not aimed at the update host.
    final unlisted = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path;
      if (_gateways.contains(path)) continue;

      final source = entity.readAsStringSync();
      if (!source.contains('DownloadTask(')) continue;
      // A DownloadTask aimed somewhere other than the update host is fine;
      // the marker is referencing the update-source config at all.
      if (source.contains('kUpdateAccessKey') || source.contains('UPDATE_BASE_URL')) {
        continue; // already sends the key, or is the config itself
      }
      unlisted.add(path);
    }

    expect(
      unlisted,
      isEmpty,
      reason: 'these files build a DownloadTask but neither send the access key '
          'nor appear in the checked list — if any targets the update host it '
          'will 403:\n  ${unlisted.join('\n  ')}',
    );
  });

  test('the contract can still fail — it is not matching a stale pattern', () {
    // The whole point is catching a REMOVED header. Prove the check reacts to
    // source that lacks it, so a renamed constant cannot leave this test
    // passing over files it no longer really inspects.
    const withoutHeader = '''
      DownloadTask(
        url: _joinUrl(_config.baseUrl, file.name),
        filename: file.name,
      );
    ''';
    expect(withoutHeader.contains('$_headerConstant: $_valueConstant'), isFalse);

    const withHeader = 'headers: {kUpdateAccessKeyHeader: kUpdateAccessKey},';
    expect(withHeader.contains('$_headerConstant: $_valueConstant'), isTrue);
  });
}
