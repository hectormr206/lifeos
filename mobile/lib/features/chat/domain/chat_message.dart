import 'dart:typed_data';

/// Who authored a [ChatMessage] (spec mobile-chat, M1 slice 2).
enum ChatRole { user, axi }

/// What kind of content a [ChatMessage] carries (WhatsApp/Telegram-style chat).
///
///   * [text]  — a plain / markdown text turn (the original slice-2 message).
///   * [image] — an attached photo (camera/gallery). Its bytes live in
///     [ChatMessage.imageBytes]; [ChatMessage.text] is the optional caption.
///   * [voice] — a recorded voice note. The playable file is at
///     [ChatMessage.audioPath] with [ChatMessage.audioDuration]. STT is a
///     future slice, so a sent voice note may carry [transcriptionPending].
enum ChatMessageKind { text, image, voice }

/// A single message in a chat conversation with Axi (spec mobile-chat).
///
/// [id] is a plain [String] (not the engine's integer `conversations.id`)
/// because a locally-created optimistic user message has no server id yet;
/// history-loaded messages derive their id from the row id + role suffix
/// (see `ChatRepository.loadHistory`) so they stay stable and unique.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.timestamp,
    this.kind = ChatMessageKind.text,
    this.imageBytes,
    this.audioPath,
    this.audioDuration,
    this.transcriptionPending = false,
  });

  final String id;
  final ChatRole role;

  /// The text body. For an [ChatMessageKind.image] message this is an optional
  /// caption (may be empty); for a [ChatMessageKind.voice] message it is a
  /// short label rather than a real transcription (STT is deferred).
  final String text;
  final DateTime timestamp;

  /// The kind of content this message carries.
  final ChatMessageKind kind;

  /// Raw bytes of an attached image ([ChatMessageKind.image] only).
  final Uint8List? imageBytes;

  /// On-disk path of a recorded voice note ([ChatMessageKind.voice] only).
  final String? audioPath;

  /// Length of the recorded voice note ([ChatMessageKind.voice] only).
  final Duration? audioDuration;

  /// A sent voice note whose speech-to-text transcription is deferred to the
  /// STT slice — the UI shows a "Transcripción pendiente (STT)" note rather
  /// than faking a transcription.
  final bool transcriptionPending;

  bool get isImage => kind == ChatMessageKind.image;
  bool get isVoice => kind == ChatMessageKind.voice;

  @override
  bool operator ==(Object other) =>
      other is ChatMessage &&
      other.id == id &&
      other.role == role &&
      other.text == text &&
      other.timestamp == timestamp &&
      other.kind == kind &&
      _sameBytes(other.imageBytes, imageBytes) &&
      other.audioPath == audioPath &&
      other.audioDuration == audioDuration &&
      other.transcriptionPending == transcriptionPending;

  @override
  int get hashCode => Object.hash(
        id,
        role,
        text,
        timestamp,
        kind,
        imageBytes?.length,
        audioPath,
        audioDuration,
        transcriptionPending,
      );

  static bool _sameBytes(Uint8List? a, Uint8List? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'ChatMessage(id: $id, role: $role, kind: $kind, text: $text)';
}
