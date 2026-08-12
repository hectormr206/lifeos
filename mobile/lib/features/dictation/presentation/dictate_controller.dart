// TODO(i18n): the fallback failure messages below are hardcoded neutral
// Spanish, matching `SherpaSttService`'s `SttException` copy. The SCREEN
// localizes the three known failure kinds (model missing, permission denied,
// recorder unavailable) from the ARB and only falls back to these strings for
// an unexpected error, where the underlying text is the useful part anyway.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/locale_providers.dart';
import '../../chat/domain/audio_recorder_gateway.dart';
import '../../chat/presentation/chat_providers.dart';
import '../../stt/domain/speech_to_text.dart';
import '../../stt/presentation/stt_providers.dart';
import '../domain/dictation_status.dart';

/// Owns one "Dictar" take: open the mic, close it, transcribe on-device.
///
/// REUSES the voice-note path's seams rather than adding a second audio stack —
/// `audioRecorderGatewayProvider` (16 kHz mono WAV, sealed through
/// `VoiceNoteFileStore`), `sttModelGatewayProvider` (is the model on disk?) and
/// `speechToTextProvider` (sherpa-onnx Whisper). All three are already
/// cross-platform, which is why this works on Android and on the Linux desktop
/// build without a platform branch.
///
/// It differs from the chat composer's mic in ONE way, deliberately: chat uses
/// press-and-hold (a phone idiom, and a poor one with a mouse), while this is
/// tap-to-start / tap-to-stop. The chat mic is untouched — it has real users on
/// the user's Pixel.
///
/// The result is left in [DictationReady] for the screen to hand to the user;
/// this controller never sends anything by itself.
class DictateController extends Notifier<DictationStatus> {
  /// The recorder instance that currently has the microphone open, captured
  /// when the take starts. Held as a field so [Ref.onDispose] can release the
  /// device without reading a provider out of a container that is already
  /// tearing down.
  AudioRecorderGateway? _openRecorder;

  @override
  DictationStatus build() {
    // The microphone must never outlive this controller. Leaving the screen
    // mid-take disposes the provider, and that alone has to release the device
    // — it cannot depend on the user tapping anything, or on the widget's
    // dispose (where `ref` is no longer usable).
    ref.onDispose(() {
      final recorder = _openRecorder;
      _openRecorder = null;
      if (recorder != null) unawaited(recorder.cancel());
    });
    return const DictationIdle();
  }

  /// Opens the microphone, after checking the two preconditions that would
  /// otherwise fail deep inside the recorder or the recognizer.
  Future<void> start() async {
    // Guard re-entry: a double tap must not open a second take and strand the
    // first one holding the microphone.
    if (state is DictationRecording || state is DictationTranscribing) return;

    // 1) The model. Probed through the GATEWAY, not the download notifier's
    // cached status — the same authoritative check `ChatNotifier` makes before
    // transcribing a voice note.
    final SttModelPathsProbe probe = _probeModel;
    if (!await probe()) {
      state = const DictationFailed(
        'El modelo de voz no está descargado en este dispositivo.',
        modelMissing: true,
      );
      return;
    }

    final recorder = ref.read(audioRecorderGatewayProvider);

    // 2) The microphone permission.
    if (!await recorder.hasPermission()) {
      state = const DictationFailed(
        'Sin permiso de micrófono, no puedo escucharte.',
        permissionDenied: true,
      );
      return;
    }

    try {
      await recorder.start();
      _openRecorder = recorder;
    } catch (e) {
      // On Linux `record_linux` launches the external `parecord` binary, so a
      // box without it lands here. Keep the underlying error in the message:
      // "no pude grabar" alone leaves the user nothing to act on.
      state = DictationFailed(
        'No se pudo abrir el micrófono: $e',
        recorderUnavailable: true,
      );
      return;
    }

    state = const DictationRecording();
  }

  /// Closes the microphone and transcribes the take on-device.
  Future<void> stop() async {
    if (state is! DictationRecording) return;

    final recorder = ref.read(audioRecorderGatewayProvider);
    state = const DictationTranscribing();

    String? path;
    try {
      path = await recorder.stop();
      _openRecorder = null;
    } catch (e) {
      state = DictationFailed('No se pudo cerrar la grabación: $e');
      return;
    }

    if (path == null) {
      // A take too short to produce a file. Unlike the chat voice note — which
      // still drops a bubble so the note is visibly not lost — there is nothing
      // to show here, so say it plainly.
      state = const DictationFailed(
        'No se capturó audio. Prueba de nuevo y habla un poco más.',
      );
      return;
    }

    final String transcript;
    try {
      transcript = await ref.read(speechToTextProvider).transcribe(
            path,
            languageCode: ref.read(appLanguageCodeProvider),
          );
    } on SttException catch (e) {
      state = DictationFailed(e.message);
      return;
    } catch (e) {
      state = DictationFailed('No se pudo transcribir: $e');
      return;
    }

    final trimmed = transcript.trim();
    if (trimmed.isEmpty) {
      // Handing back a blank field with no explanation is exactly the quiet
      // degradation the repo forbids.
      state = const DictationFailed(
        'No se entendió nada. Prueba de nuevo, más cerca del micrófono.',
      );
      return;
    }

    state = DictationReady(trimmed);
  }

  /// Discards the take in progress and releases the microphone.
  Future<void> cancel() async {
    if (state is! DictationRecording) {
      // Nothing is open; leaving [DictationIdle] alone keeps a stray cancel
      // from clearing a transcript the user is still editing.
      if (state is DictationIdle) return;
      state = const DictationIdle();
      return;
    }
    _openRecorder = null;
    await ref.read(audioRecorderGatewayProvider).cancel();
    state = const DictationIdle();
  }

  /// Clears the result (or the error) so the next take starts clean.
  void reset() => state = const DictationIdle();

  Future<bool> _probeModel() async =>
      await ref.read(sttModelGatewayProvider).installedModel() != null;

  /// Kicks off the voice-model download, reusing the chat banner's notifier so
  /// there is one download in flight and one place that reports its progress.
  Future<void> downloadModel() =>
      ref.read(sttModelDownloadProvider.notifier).download();
}

/// Signature of the "is the model on disk?" probe — named so [DictateController]
/// reads as a sequence of preconditions rather than nested awaits.
typedef SttModelPathsProbe = Future<bool> Function();

/// The current dictation take. Auto-disposed with the screen so a stale
/// transcript never reappears on the next visit.
final dictateControllerProvider =
    NotifierProvider<DictateController, DictationStatus>(DictateController.new);
