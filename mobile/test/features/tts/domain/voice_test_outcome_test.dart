// Proves the "Probar voz" outcome model: every failure maps to exactly one
// recovery (derived, never hand-wired per call site), and both outcome shapes
// carry value equality so a widget can compare them without identity games.
//
// The exhaustiveness matters: adding a failure without deciding what the user
// can DO about it is how "Inténtalo de nuevo" ends up on a permanent failure.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/tts/domain/voice_test_outcome.dart';

void main() {
  group('VoiceTestFailure.recovery', () {
    test('a voice that is simply not downloaded offers the download', () {
      expect(VoiceTestFailure.voiceMissing.recovery, VoiceTestRecovery.downloadVoice);
    });

    test('an incompatible voice offers another voice, never a retry', () {
      expect(
        VoiceTestFailure.voiceIncompatible.recovery,
        VoiceTestRecovery.chooseAnotherVoice,
      );
    });

    test('transient engine failures offer a retry', () {
      expect(VoiceTestFailure.synthesisFailed.recovery, VoiceTestRecovery.retry);
      expect(VoiceTestFailure.emptySynthesis.recovery, VoiceTestRecovery.retry);
      expect(VoiceTestFailure.playbackFailed.recovery, VoiceTestRecovery.retry);
      // Unattributable is still worth one retry — it is the only honest offer
      // when we do not know which step broke.
      expect(VoiceTestFailure.unknown.recovery, VoiceTestRecovery.retry);
    });

    test('no engine at all offers nothing — there is nothing here to tap', () {
      expect(VoiceTestFailure.noEngine.recovery, VoiceTestRecovery.none);
    });

    test('every failure has a recovery (exhaustive, no default branch)', () {
      for (final failure in VoiceTestFailure.values) {
        expect(failure.recovery, isA<VoiceTestRecovery>(),
            reason: 'no recovery decided for ${failure.name}');
      }
    });
  });

  group('outcome value semantics', () {
    test('spoke compares by engine and by the neural failure it fell back from', () {
      expect(
        const VoiceTestSpoke(VoiceTestEngine.neural),
        const VoiceTestSpoke(VoiceTestEngine.neural),
      );
      expect(
        const VoiceTestSpoke(VoiceTestEngine.neural).hashCode,
        const VoiceTestSpoke(VoiceTestEngine.neural).hashCode,
      );
      expect(
        const VoiceTestSpoke(VoiceTestEngine.system),
        isNot(const VoiceTestSpoke(VoiceTestEngine.neural)),
      );
      expect(
        const VoiceTestSpoke(VoiceTestEngine.system,
            neuralFailure: VoiceTestFailure.voiceMissing),
        isNot(const VoiceTestSpoke(VoiceTestEngine.system)),
      );
    });

    test('failed compares by failure and detail', () {
      expect(
        const VoiceTestFailed(VoiceTestFailure.noEngine),
        const VoiceTestFailed(VoiceTestFailure.noEngine),
      );
      expect(
        const VoiceTestFailed(VoiceTestFailure.noEngine, detail: 'boom'),
        isNot(const VoiceTestFailed(VoiceTestFailure.noEngine)),
      );
      expect(
        const VoiceTestFailed(VoiceTestFailure.noEngine),
        isNot(const VoiceTestFailed(VoiceTestFailure.unknown)),
      );
    });

    test('toString names the case, for logs and test failure output', () {
      expect(
        const VoiceTestSpoke(VoiceTestEngine.system).toString(),
        contains('system'),
      );
      expect(
        const VoiceTestFailed(VoiceTestFailure.synthesisFailed).toString(),
        contains('synthesisFailed'),
      );
    });
  });
}
