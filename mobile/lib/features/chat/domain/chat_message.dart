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
///   * [image] — one or more attached photos (camera/gallery). Their bytes live
///     in [ChatMessage.images] (WhatsApp-style multi-attach); [ChatMessage.text]
///     is the optional caption sent together with them in one turn.
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
    this.images = const [],
    this.audioPath,
    this.audioDuration,
    this.transcription,
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

  /// Raw bytes of the attached photos ([ChatMessageKind.image] only), in the
  /// order the user added them. Empty for non-image messages. A single-image
  /// message is just a one-element list.
  final List<Uint8List> images;

  /// Convenience accessor for the first attached image (or null when there are
  /// none) — kept so single-image call sites read naturally.
  Uint8List? get imageBytes => images.isEmpty ? null : images.first;

  /// On-disk path of a recorded voice note ([ChatMessageKind.voice] only).
  final String? audioPath;

  /// Length of the recorded voice note ([ChatMessageKind.voice] only).
  final Duration? audioDuration;

  /// The on-device (Whisper) speech-to-text result for a voice note, kept
  /// SEPARATE from [text] so the bubble can show the audio with the transcript
  /// hidden by default and revealed on tap. This is exactly what is fed to Axi;
  /// storing it here is a PRESENTATION concern only. Null until STT completes
  /// (see [transcriptionPending]) and for every non-voice message.
  final String? transcription;

  /// A sent voice note whose speech-to-text transcription has not resolved yet
  /// — the UI shows a "Transcripción pendiente (STT)" note rather than a
  /// transcript expander. Cleared once [transcription] is set.
  final bool transcriptionPending;

  /// A voice note with a recognized transcript ready to reveal on tap.
  bool get hasTranscription => transcription != null && transcription!.isNotEmpty;

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
  ChatMessage copyWith({
    ChatMessageStatus? status,
    GenerationMetrics? metrics,
    String? transcription,
    bool? transcriptionPending,
  }) =>
      ChatMessage(
        id: id,
        role: role,
        text: text,
        timestamp: timestamp,
        kind: kind,
        images: images,
        audioPath: audioPath,
        audioDuration: audioDuration,
        transcription: transcription ?? this.transcription,
        transcriptionPending: transcriptionPending ?? this.transcriptionPending,
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
      _sameImages(other.images, images) &&
      other.audioPath == audioPath &&
      other.audioDuration == audioDuration &&
      other.transcription == transcription &&
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
        Object.hashAll(images.map((b) => b.length)),
        audioPath,
        audioDuration,
        transcription,
        transcriptionPending,
        status,
        metrics,
      );

  static bool _sameImages(List<Uint8List> a, List<Uint8List> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameBytes(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() => 'ChatMessage(id: $id, role: $role, kind: $kind, text: $text)';
}
