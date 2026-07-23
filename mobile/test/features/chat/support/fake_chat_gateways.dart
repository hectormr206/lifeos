import 'dart:async';
import 'dart:typed_data';

import 'package:lifeos/features/chat/domain/audio_player_gateway.dart';
import 'package:lifeos/features/chat/domain/audio_recorder_gateway.dart';
import 'package:lifeos/features/chat/domain/image_picker_gateway.dart';
import 'package:lifeos/features/chat/domain/text_to_speech_gateway.dart';
import 'package:lifeos/features/chat/domain/voice_reply_preferences.dart';

/// In-memory [ImagePickerGateway] — no plugin channel, no OS picker. Returns
/// scripted [bytes] and records the requested [PhotoSource].
class FakeImagePickerGateway implements ImagePickerGateway {
  FakeImagePickerGateway({this.bytes});

  Uint8List? bytes;
  final List<PhotoSource> requested = [];

  @override
  Future<Uint8List?> pickImage(PhotoSource source) async {
    requested.add(source);
    return bytes;
  }
}

/// In-memory [AudioRecorderGateway] — no microphone. Scriptable permission,
/// counts start/stop/cancel so the press-and-hold flow is host-testable.
class FakeAudioRecorderGateway implements AudioRecorderGateway {
  FakeAudioRecorderGateway({
    this.permission = true,
    this.path = '/tmp/fake-voice.m4a',
    this.stopReturnsNull = false,
  });

  bool permission;
  String path;
  // Simulates a very short/empty take: recorder.stop() yields no file (null).
  bool stopReturnsNull;

  int startCount = 0;
  int stopCount = 0;
  int cancelCount = 0;
  bool _recording = false;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<String> start() async {
    startCount++;
    _recording = true;
    return path;
  }

  @override
  Future<String?> stop() async {
    stopCount++;
    _recording = false;
    return stopReturnsNull ? null : path;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    _recording = false;
  }

  @override
  Future<bool> isRecording() async => _recording;
}

/// In-memory [AudioPlayerGateway] — no audio output. Records played paths and
/// drives the [playingStream] so a bubble's play/pause toggle is testable.
class FakeAudioPlayerGateway implements AudioPlayerGateway {
  final List<String> played = [];
  final _controller = StreamController<bool>.broadcast();
  int pauseCount = 0;

  @override
  Future<void> play(String path) async {
    played.add(path);
    _controller.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _controller.add(false);
  }

  @override
  Future<void> stop() async => _controller.add(false);

  @override
  Stream<bool> get playingStream => _controller.stream;

  @override
  Future<void> dispose() async => _controller.close();
}

/// In-memory [TextToSpeechGateway] — no real TTS engine. Records spoken text
/// and stop calls, and can simulate an utterance finishing on its own via
/// [complete] so the speak ↔ stop toggle is host-testable.
class FakeTextToSpeechGateway implements TextToSpeechGateway {
  final List<String> spoken = [];
  int stopCount = 0;
  final _completions = StreamController<void>.broadcast();

  @override
  Future<void> speak(String text) async => spoken.add(text);

  @override
  Future<void> stop() async => stopCount++;

  /// Test hook: simulate the current utterance finishing naturally.
  void complete() => _completions.add(null);

  @override
  Stream<void> get completions => _completions.stream;

  @override
  Future<void> dispose() async => _completions.close();
}

/// In-memory [VoiceReplyPreferences] — no shared_preferences channel.
class FakeVoiceReplyPreferences implements VoiceReplyPreferences {
  FakeVoiceReplyPreferences({bool enabled = false}) : _enabled = enabled;

  bool _enabled;
  int writes = 0;

  bool get persisted => _enabled;

  @override
  Future<bool> isEnabled() async => _enabled;

  @override
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    writes++;
  }
}
