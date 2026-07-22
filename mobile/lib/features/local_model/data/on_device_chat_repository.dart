import 'dart:typed_data';

import '../../chat/data/chat_repository.dart';
import '../../chat/domain/chat_message.dart';
import '../domain/local_llm_engine.dart';

/// A [ChatRepository] that answers entirely on-device via a [LocalLlmEngine]
/// (roadmap SLICE 1) instead of hitting the paired engine over HTTP — the
/// offline path behind the existing chat UI.
///
/// SLICE 1 scope: text-only, non-streaming, single-turn. [loadHistory]
/// returns `[]` (no local conversation persistence yet — TODO(roadmap)).
class OnDeviceChatRepository implements ChatRepository {
  OnDeviceChatRepository(this._engine);

  final LocalLlmEngine _engine;

  /// Serialises access to the engine: an on-device model has one native
  /// context, so overlapping [sendMessage] calls (double-tap send, races)
  /// must run one-at-a-time rather than corrupt shared state.
  Future<void> _lock = Future<void>.value();

  /// Lazily load the weights exactly once, guarded so concurrent first calls
  /// don't double-load.
  Future<void>? _loadFuture;

  Future<T> _serialize<T>(Future<T> Function() task) {
    final result = _lock.then((_) => task());
    // Chain the lock on completion (success OR failure) so one failed call
    // never wedges the queue.
    _lock = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<ChatMessage> sendMessage(String text) => _serialize(() async {
        try {
          await (_loadFuture ??= _engine.load());
          final result = await _engine.generate(text);
          return ChatMessage(
            id: 'local-${DateTime.now().microsecondsSinceEpoch}',
            role: ChatRole.axi,
            text: result.text,
            timestamp: DateTime.now(),
            // Per-response metrics ride along so the chat UI can show tokens/s +
            // latency under the bubble and full stats in a modal.
            metrics: result.metrics,
          );
        } catch (error) {
          // Reset so a later attempt can retry loading after a transient
          // failure (e.g. model not installed yet).
          _loadFuture = null;
          throw ChatException('Axi (modelo local) no pudo responder: $error');
        }
      });

  @override
  Future<ChatMessage> sendImages(String text, List<Uint8List> images) => _serialize(() async {
        try {
          await (_loadFuture ??= _engine.load());
          // Routes to the on-device model's VISION path (all photos in one
          // turn). If the installed variant is text-only, the engine throws and
          // we surface a clear Spanish message rather than silently dropping the
          // photos.
          final result = await _engine.generateWithImages(text, images);
          return ChatMessage(
            id: 'local-${DateTime.now().microsecondsSinceEpoch}',
            role: ChatRole.axi,
            text: result.text,
            timestamp: DateTime.now(),
            metrics: result.metrics,
          );
        } catch (error) {
          _loadFuture = null;
          throw ChatException(
            'Axi (modelo local) no pudo analizar la imagen. '
            'Puede que este modelo no soporte visión en este dispositivo. ($error)',
          );
        }
      });

  @override
  Future<List<ChatMessage>> loadHistory() async => const <ChatMessage>[];
}
