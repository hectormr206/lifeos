import 'package:audioplayers/audioplayers.dart';

import '../domain/audio_player_gateway.dart';

/// [AudioPlayerGateway] backed by the real `audioplayers` package. A single
/// shared player instance is reused across bubbles (tapping a new note stops
/// the previous one).
class AudioPlayersAudioPlayerGateway implements AudioPlayerGateway {
  AudioPlayersAudioPlayerGateway([AudioPlayer? player]) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Future<void> play(String path) async {
    await _player.stop();
    await _player.play(DeviceFileSource(path));
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Stream<bool> get playingStream =>
      _player.onPlayerStateChanged.map((state) => state == PlayerState.playing);

  @override
  Future<void> dispose() => _player.dispose();
}
