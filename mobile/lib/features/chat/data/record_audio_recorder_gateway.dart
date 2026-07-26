import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../domain/audio_recorder_gateway.dart';
import '../../../core/security/voice_note_file_store.dart';

/// [AudioRecorderGateway] backed by the real `record` package.
///
/// Roadmap slice B2 (on-device STT): voice notes are now recorded as
/// **16 kHz mono PCM16 WAV** ([sttRecordConfig]) instead of AAC/m4a. This is
/// exactly the format the offline sherpa-onnx Whisper recognizer expects — its
/// `readWave` parses a RIFF/WAV header and requires 16 kHz mono — so a recorded
/// note can be transcribed on-device with no resample/transcode step.
///
/// `AudioEncoder.wav` (NOT `AudioEncoder.pcm16bits`) is used on purpose: the
/// `record` package's `pcm16bits` encoder writes HEADERLESS raw PCM, which
/// `readWave` cannot parse; `AudioEncoder.wav` writes the same PCM16 samples
/// wrapped in a WAV container (with the RIFF header), which both sherpa-onnx
/// AND the audioplayers playback path read directly. One file per recording.
class RecordAudioRecorderGateway implements AudioRecorderGateway {
  RecordAudioRecorderGateway([
    AudioRecorder? recorder,
    VoiceNoteFileStore? voiceNotes,
  ]) : _recorder = recorder ?? AudioRecorder(),
       _voiceNotes = voiceNotes ?? VoiceNoteFileStore();

  final AudioRecorder _recorder;
  final VoiceNoteFileStore _voiceNotes;
  // The file the current take is being written to, so [cancel] can delete it.
  String? _currentPath;

  /// The 16 kHz mono PCM16 WAV capture config. Exposed for testing so the
  /// format contract (what the STT recognizer needs) is asserted without a
  /// microphone or platform channel.
  @visibleForTesting
  static const RecordConfig sttRecordConfig = RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 16000,
    numChannels: 1,
  );

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<String> start() async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice-${DateTime.now().microsecondsSinceEpoch}.wav';
    await _recorder.start(sttRecordConfig, path: path);
    _currentPath = path;
    return path;
  }

  @override
  Future<String?> stop() async {
    final path = await _recorder.stop();
    _currentPath = null;
    return path == null ? null : _voiceNotes.sealRecording(path);
  }

  @override
  Future<void> cancel() async {
    // Slide-to-cancel: stop the recorder and delete the temp file so a
    // discarded note leaves nothing behind.
    final path = await _recorder.stop() ?? _currentPath;
    _currentPath = null;
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Best-effort cleanup; the OS reclaims temp files anyway.
    }
  }

  @override
  Future<bool> isRecording() => _recorder.isRecording();
}
