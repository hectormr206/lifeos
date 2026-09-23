// Proves the recorder captures the exact format the offline sherpa-onnx
// Whisper recognizer needs (roadmap slice B2): 16 kHz mono PCM16 WAV. The
// config is asserted directly (no microphone / platform channel).
//
// The stop() path is also exercised against a fake recorder and a fake
// path_provider platform: the sealed note must land in the DURABLE voice-note
// directory, not in the temp dir the WAV was recorded into.
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/core/security/encrypted_file_cipher.dart';
import 'package:lifeos/core/security/voice_note_directory.dart';
import 'package:lifeos/core/security/voice_note_file_store.dart';
import 'package:lifeos/features/chat/data/record_audio_recorder_gateway.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:record/record.dart';

/// Redirects `getTemporaryDirectory()` / `getApplicationSupportDirectory()`
/// to temp dirs, so no path_provider platform channel is needed in tests.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.temporaryPath, this.applicationSupportPath);

  final String temporaryPath;
  final String applicationSupportPath;

  @override
  Future<String?> getTemporaryPath() async => temporaryPath;

  @override
  Future<String?> getApplicationSupportPath() async => applicationSupportPath;
}

/// The `record` platform channel. In record 7.x `AudioRecorder`'s constructor
/// performs real platform I/O (`create`) before any method is called, so a fake
/// that merely `extends AudioRecorder` can never be constructed headlessly: the
/// superclass constructor immediately invokes this channel and throws
/// `MissingPluginException`. Mocking the channel instead lets the test drive the
/// REAL AudioRecorder, exercising the production construction path too.
const _recordChannel = MethodChannel('com.llfbandit.record/messages');

/// Installs a fake platform for the record channel that behaves like a device
/// mic: `start` materializes the file the platform would have written, `stop`
/// hands that same path back.
void _installFakeRecordPlatform() {
  String? startedPath;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_recordChannel, (call) async {
    switch (call.method) {
      case 'start':
        final args = Map<Object?, Object?>.from(call.arguments as Map);
        final path = args['path'] as String?;
        startedPath = path;
        if (path != null) await File(path).create(recursive: true);
        return null;
      case 'stop':
        final path = startedPath;
        startedPath = null;
        return path;
      case 'isRecording':
        return startedPath != null;
      case 'isPaused':
        return false;
      case 'hasPermission':
      case 'isEncoderSupported':
        return true;
      case 'listInputDevices':
        return <String>[];
      default:
        // create / dispose / pause / resume / cancel are void on the platform.
        return null;
    }
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_recordChannel, null));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('records 16 kHz mono PCM16 WAV (the format Whisper readWave expects)', () {
    const config = RecordAudioRecorderGateway.sttRecordConfig;
    // AudioEncoder.wav (PCM16 in a WAV container with a RIFF header) — NOT
    // pcm16bits (headerless raw PCM), which readWave cannot parse.
    expect(config.encoder, AudioEncoder.wav);
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
  });

  test('stop() seals the recording INTO the durable directory, not temp', () async {
    final root = await Directory.systemTemp.createTemp('lifeos-recorder-');
    addTearDown(() => root.delete(recursive: true));
    final tempDir = Directory('${root.path}/tmp')..createSync();
    final supportDir = Directory('${root.path}/support')..createSync();

    final originalPlatform = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProviderPlatform(
      tempDir.path,
      supportDir.path,
    );
    addTearDown(() => PathProviderPlatform.instance = originalPlatform);

    _installFakeRecordPlatform();

    final gateway = RecordAudioRecorderGateway(
      AudioRecorder(),
      VoiceNoteFileStore(
        cipher: EncryptedFileCipher(
          keyProvider: () async => SecretKey(List<int>.filled(32, 7)),
        ),
        durableDirectory: VoiceNoteDirectory(
          directoryProvider: () async => supportDir,
        ),
        // The scratch dir defaults to getTemporaryDirectory(), which the fake
        // platform above redirects to tempDir — exactly like production.
      ),
    );

    final recordedPath = await gateway.start();
    // The recording itself is scratch data in the temp dir…
    expect(recordedPath, startsWith(tempDir.path));
    await File(recordedPath).writeAsBytes([1, 2, 3, 4]);

    final sealedPath = (await gateway.stop())!;

    // …but the sealed note lands in the DURABLE voice_notes directory under
    // app support, NOT in the temp dir it was recorded into.
    expect(
      sealedPath,
      '${supportDir.path}/voice_notes/${recordedPath.split('/').last}.lifeos',
    );
    expect(File(sealedPath).existsSync(), isTrue);
    expect(File(sealedPath).parent.path, '${supportDir.path}/voice_notes');
    expect(sealedPath.startsWith(tempDir.path), isFalse);
    // The plaintext temp recording is gone once sealed.
    expect(File(recordedPath).existsSync(), isFalse);
  });
}
