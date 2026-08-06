// Proves the Dictar flow: press → capture mic → transcribe locally → hand the
// text back for the user to use.
//
// It REUSES the voice-note path's three seams rather than inventing a second
// one — `audioRecorderGatewayProvider`, `sttModelGatewayProvider` and
// `speechToTextProvider` — so it is fully host-testable with no microphone, no
// model and no native runtime. That matters here: this machine is headless.
//
// The two product rules meet in this file and they pull in opposite directions,
// so both are asserted:
//   * A capability the platform does NOT have is absent (see
//     `supportsDictation` in app_platform_test / dictate_screen_test).
//   * A capability that IS attempted and fails says so LOUDLY — it never
//     degrades into silence. Every failure path below lands in
//     [DictationFailed] with a message, never back in [DictationIdle].
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/presentation/chat_providers.dart';
import 'package:lifeos/features/dictation/domain/dictation_status.dart';
import 'package:lifeos/features/dictation/presentation/dictate_controller.dart';
import 'package:lifeos/features/stt/domain/speech_to_text.dart';
import 'package:lifeos/features/stt/domain/stt_model.dart';
import 'package:lifeos/features/stt/presentation/stt_providers.dart';
import 'package:lifeos/l10n/language_preference.dart';
import 'package:lifeos/l10n/locale_providers.dart';

import '../chat/support/fake_chat_gateways.dart';
import '../stt/support/fake_stt.dart';
import '../../support/fake_language_preferences.dart';

const _installed = SttModelPaths(encoder: 'e.onnx', decoder: 'd.onnx', tokens: 't.txt');

({ProviderContainer container, DictateController controller}) harness({
  FakeAudioRecorderGateway? recorder,
  FakeSpeechToText? stt,
  FakeSttModelGateway? model,
  AppLanguage language = AppLanguage.es,
}) {
  final container = ProviderContainer(overrides: [
    audioRecorderGatewayProvider.overrideWithValue(recorder ?? FakeAudioRecorderGateway()),
    speechToTextProvider.overrideWithValue(stt ?? FakeSpeechToText(transcript: 'hola axi')),
    sttModelGatewayProvider
        .overrideWithValue(model ?? FakeSttModelGateway(installed: _installed)),
    languagePreferencesProvider
        .overrideWithValue(FakeLanguagePreferences(initial: language)),
  ]);
  addTearDown(container.dispose);
  return (
    container: container,
    controller: container.read(dictateControllerProvider.notifier),
  );
}

void main() {
  test('starts idle', () {
    final h = harness();
    expect(h.container.read(dictateControllerProvider), isA<DictationIdle>());
  });

  group('the happy path', () {
    test('start → recording, stop → transcribing → ready with the transcript',
        () async {
      final recorder = FakeAudioRecorderGateway(path: '/tmp/take.wav');
      final stt = FakeSpeechToText(transcript: '  recordame comprar pan  ');
      final h = harness(recorder: recorder, stt: stt);

      await h.controller.start();
      expect(h.container.read(dictateControllerProvider), isA<DictationRecording>());
      expect(recorder.startCount, 1);

      await h.controller.stop();
      final state = h.container.read(dictateControllerProvider);
      expect(state, isA<DictationReady>());
      // Trimmed: the transcript is what the user will send, not raw padding.
      expect((state as DictationReady).text, 'recordame comprar pan');
      expect(recorder.stopCount, 1);
    });

    test('transcribes the recorded file in the app language', () async {
      final stt = FakeSpeechToText(transcript: 'hello axi');
      final h = harness(
        recorder: FakeAudioRecorderGateway(path: '/tmp/take.wav'),
        stt: stt,
        language: AppLanguage.en,
      );
      await h.container.read(languageProvider.notifier).ready;

      await h.controller.start();
      await h.controller.stop();

      expect(stt.lastWavPath, '/tmp/take.wav');
      expect(stt.lastLanguageCode, 'en');
    });

    test('reset returns to idle so the next take starts clean', () async {
      final h = harness();
      await h.controller.start();
      await h.controller.stop();
      expect(h.container.read(dictateControllerProvider), isA<DictationReady>());

      h.controller.reset();
      expect(h.container.read(dictateControllerProvider), isA<DictationIdle>());
    });
  });

  group('failures are LOUD — never a silent return to idle', () {
    test('an absent voice model refuses to record and says the model is missing',
        () async {
      final recorder = FakeAudioRecorderGateway();
      final h = harness(
        recorder: recorder,
        model: FakeSttModelGateway(installed: null),
      );

      await h.controller.start();

      final state = h.container.read(dictateControllerProvider);
      expect(state, isA<DictationFailed>());
      // The UI needs to distinguish this one: it is the only failure the user
      // can fix from inside the app, by downloading the model.
      expect((state as DictationFailed).modelMissing, isTrue);
      expect(state.message, isNotEmpty);
      // And it must not have opened the microphone for a take it cannot use.
      expect(recorder.startCount, 0);
    });

    test('a denied microphone permission is reported, not swallowed', () async {
      final recorder = FakeAudioRecorderGateway(permission: false);
      final h = harness(recorder: recorder);

      await h.controller.start();

      final state = h.container.read(dictateControllerProvider);
      expect(state, isA<DictationFailed>());
      expect((state as DictationFailed).permissionDenied, isTrue);
      expect(recorder.startCount, 0);
    });

    test(
        'a recorder that cannot start is reported with the underlying error '
        '(the Linux missing-parecord case)', () async {
      final recorder = FakeAudioRecorderGateway(
        startError: Exception('parecord: command not found'),
      );
      final h = harness(recorder: recorder);

      await h.controller.start();

      final state = h.container.read(dictateControllerProvider);
      expect(state, isA<DictationFailed>());
      final failed = state as DictationFailed;
      expect(failed.modelMissing, isFalse);
      // The real cause has to survive into the message — "no pude grabar" alone
      // would leave the user with nothing to act on.
      expect(failed.message, contains('parecord'));
      expect(failed.recorderUnavailable, isTrue);
    });

    test('a take that produced no file is reported', () async {
      final recorder = FakeAudioRecorderGateway(stopReturnsNull: true);
      final h = harness(recorder: recorder);

      await h.controller.start();
      await h.controller.stop();

      final state = h.container.read(dictateControllerProvider);
      expect(state, isA<DictationFailed>());
      expect((state as DictationFailed).message, isNotEmpty);
    });

    test('an SttException surfaces its message', () async {
      final stt = FakeSpeechToText(error: SttException('el modelo no cargó'));
      final h = harness(stt: stt);

      await h.controller.start();
      await h.controller.stop();

      final state = h.container.read(dictateControllerProvider);
      expect(state, isA<DictationFailed>());
      expect((state as DictationFailed).message, contains('el modelo no cargó'));
    });

    test('an unexpected error is still reported rather than hanging', () async {
      final stt = FakeSpeechToText(error: StateError('boom'));
      final h = harness(stt: stt);

      await h.controller.start();
      await h.controller.stop();

      final state = h.container.read(dictateControllerProvider);
      expect(state, isA<DictationFailed>());
      expect((state as DictationFailed).message, isNotEmpty);
    });

    test('an empty transcript is reported, not returned as empty text', () async {
      // Silence in, silence out would hand the user a blank field with no
      // explanation — exactly the quiet degradation the repo forbids.
      final h = harness(stt: FakeSpeechToText(transcript: '   '));

      await h.controller.start();
      await h.controller.stop();

      final state = h.container.read(dictateControllerProvider);
      expect(state, isA<DictationFailed>());
      expect((state as DictationFailed).message, isNotEmpty);
    });
  });

  group('the microphone is never left hot', () {
    test('cancel stops the recorder and returns to idle', () async {
      final recorder = FakeAudioRecorderGateway();
      final h = harness(recorder: recorder);

      await h.controller.start();
      await h.controller.cancel();

      expect(h.container.read(dictateControllerProvider), isA<DictationIdle>());
      expect(recorder.cancelCount, 1);
    });

    test('cancel while idle is a no-op, not an error', () async {
      final recorder = FakeAudioRecorderGateway();
      final h = harness(recorder: recorder);

      await h.controller.cancel();

      expect(h.container.read(dictateControllerProvider), isA<DictationIdle>());
      expect(recorder.cancelCount, 0);
    });

    test('a second start while recording does not open a second take', () async {
      final recorder = FakeAudioRecorderGateway();
      final h = harness(recorder: recorder);

      await h.controller.start();
      await h.controller.start();

      expect(recorder.startCount, 1);
      expect(h.container.read(dictateControllerProvider), isA<DictationRecording>());
    });

    test('stop while idle does nothing', () async {
      final recorder = FakeAudioRecorderGateway();
      final h = harness(recorder: recorder);

      await h.controller.stop();

      expect(recorder.stopCount, 0);
      expect(h.container.read(dictateControllerProvider), isA<DictationIdle>());
    });
  });
}
