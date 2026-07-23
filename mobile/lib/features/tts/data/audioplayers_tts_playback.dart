import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';

import '../domain/tts_playback.dart';

/// [TtsPlayback] backed by the existing `audioplayers` dependency, playing the
/// synthesized WAV straight from memory ([BytesSource] — no temp file).
///
/// The [AudioPlayer] is created LAZILY on the first play so merely building
/// the provider graph (e.g. in widget tests, where the plugin channel is
/// absent) never touches the platform.
class AudioplayersTtsPlayback implements TtsPlayback {
  AudioplayersTtsPlayback([AudioPlayer? player]) : _player = player;

  AudioPlayer? _player;
  StreamSubscription<void>? _completeSub;
  final _completions = StreamController<void>.broadcast();

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer();
    // Natural end of playback → completions (a deliberate stop() never fires
    // onPlayerComplete, which matches the gateway contract).
    _completeSub = player.onPlayerComplete.listen((_) {
      if (!_completions.isClosed) _completions.add(null);
    });
    _player = player;
    return player;
  }

  @override
  Future<void> play(Uint8List wavBytes) async {
    final player = _ensurePlayer();
    await player.stop();
    await player.play(BytesSource(wavBytes, mimeType: 'audio/wav'));
  }

  @override
  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (_) {
      // No player / dead channel — nothing to stop.
    }
  }

  @override
  Stream<void> get completions => _completions.stream;

  @override
  Future<void> dispose() async {
    await _completeSub?.cancel();
    try {
      await _player?.dispose();
    } catch (_) {
      // The platform channel may be gone (shutdown / widget test) — never let
      // teardown throw.
    }
    _player = null;
    await _completions.close();
  }
}
