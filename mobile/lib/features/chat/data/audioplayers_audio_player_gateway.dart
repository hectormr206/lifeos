import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import '../domain/audio_player_gateway.dart';
import '../../../core/security/voice_note_file_store.dart';

/// [AudioPlayerGateway] backed by the real `audioplayers` package. A single
/// shared player instance is reused across bubbles (tapping a new note stops
/// the previous one).
class AudioPlayersAudioPlayerGateway implements AudioPlayerGateway {
  AudioPlayersAudioPlayerGateway([
    AudioPlayer? player,
    VoiceNoteFileStore? voiceNotes,
  ]) : _player = player ?? AudioPlayer(),
       _voiceNotes = voiceNotes ?? VoiceNoteFileStore() {
    _completionSubscription = _player.onPlayerComplete.listen(
      (_) => _removeTemporary(),
    );
  }

  final AudioPlayer _player;
  final VoiceNoteFileStore _voiceNotes;
  String? _temporaryPath;
  late final StreamSubscription<void> _completionSubscription;

  @override
  Future<void> play(String path) async {
    await _player.stop();
    await _removeTemporary();
    final playablePath = await _voiceNotes.decryptToTemporaryWav(path);
    if (playablePath != path) _temporaryPath = playablePath;
    await _player.play(DeviceFileSource(playablePath));
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    await _player.stop();
    await _removeTemporary();
  }

  @override
  Stream<bool> get playingStream =>
      _player.onPlayerStateChanged.map((state) => state == PlayerState.playing);

  @override
  Future<void> dispose() async {
    await _completionSubscription.cancel();
    await _player.dispose();
    await _removeTemporary();
  }

  Future<void> _removeTemporary() async {
    final path = _temporaryPath;
    _temporaryPath = null;
    if (path != null) await _voiceNotes.deleteTemporaryWav(path);
  }
}
