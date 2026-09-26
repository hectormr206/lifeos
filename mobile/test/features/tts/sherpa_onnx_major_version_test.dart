// A tripwire for sherpa-onnx 2.0, which will break every Piper voice.
//
// sherpa-onnx announced it will remove espeak-ng and piper-phonemize in a
// major release, 2.0.0, to stay Apache-2.0 (k2-fsa/sherpa-onnx#3731, open
// and not yet released as of 2026-09-25). Every Piper voice in LifeOS
// phonemizes through espeak-ng: SherpaPiperSpeechSynthesizer passes the
// extracted `espeak-ng-data` directory as `dataDir`. On 2.x that path is gone
// and the voices stop speaking, on every device, with no compile error to
// warn anyone.
//
// The `^1.13.4` constraint keeps 2.x out today, but a
// `flutter pub upgrade --major-versions` would let it in silently. This test
// fails loudly instead, and says what the migration is:
//   1. give each Piper voice the `lexicon.txt` upstream adds next to every
//      model and pass it to OfflineTtsVitsModelConfig instead of `dataDir`;
//      or
//   2. phonemize outside sherpa-onnx (LifeOS is AGPL, so it MAY ship
//      espeak-ng itself) and pass the tokens through the new generation
//      field upstream is adding.
// Then update this test to the new major version.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sherpa-onnx stays on 1.x until Piper no longer needs espeak-ng', () {
    final lock = File('pubspec.lock').readAsStringSync();
    final entry = RegExp(r'\n  sherpa_onnx:\n(?:    .*\n)*?    version: "(\d+)\.')
        .firstMatch(lock);

    expect(entry, isNotNull, reason: 'sherpa_onnx is no longer in pubspec.lock');
    expect(
      entry!.group(1),
      '1',
      reason: 'sherpa-onnx ${entry.group(1)}.x removed espeak-ng '
          '(k2-fsa/sherpa-onnx#3731): every Piper voice stops speaking. '
          'Migrate SherpaPiperSpeechSynthesizer to lexicon.txt or external '
          'phonemization first; see the comment at the top of this test.',
    );
  });
}
