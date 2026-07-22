import 'dart:typed_data';

import '../../local_model/domain/generation_metrics.dart';

/// Who authored a [ChatMessage] (spec mobile-chat, M1 slice 2).
enum ChatRole { user, axi }

/// Delivery state of an OUTGOING (user) message, rendered as WhatsApp-style
/// checkmarks in the bubble's meta line:
///   * [sending]   — optimistically shown, request not yet dispatched (a clock).
///   * [sent]      — handed to the engine/repository (single ✓).
///   * [delivered] — Axi's reply came back (double ✓✓).
///
/// Only user messages that are actually sent carry a status; history-loaded and
/// Axi messages leave it null (no checkmark), and voice notes — never sent to
/// Axi this slice — also leave it null.
enum ChatMessageStatus { sending, sent, delivered }

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
    this.status,
    this.metrics,
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

  /// Delivery status for an outgoing user message (WhatsApp checkmarks); null
  /// for Axi/history/voice messages that show no checkmark.
  final ChatMessageStatus? status;

  /// Per-response performance metrics for an on-device Axi reply; null for user
  /// messages and for HTTP replies (server round-trips carry no local metrics).
  final GenerationMetrics? metrics;

  bool get isImage => kind == ChatMessageKind.image;
  bool get isVoice => kind == ChatMessageKind.voice;

  /// Returns a copy with the given fields replaced. Used to advance a user
  /// message's [status] (sending → sent → delivered) without rebuilding it.
  ChatMessage copyWith({ChatMessageStatus? status, GenerationMetrics? metrics}) => ChatMessage(
        id: id,
        role: role,
        text: text,
        timestamp: timestamp,
        kind: kind,
        imageBytes: imageBytes,
        audioPath: audioPath,
        audioDuration: audioDuration,
        transcriptionPending: transcriptionPending,
        status: status ?? this.status,
        metrics: metrics ?? this.metrics,
      );

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
      other.transcriptionPending == transcriptionPending &&
      other.status == status &&
      other.metrics == metrics;

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
        status,
        metrics,
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
