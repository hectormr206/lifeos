/// Who authored a [ChatMessage] (spec mobile-chat, M1 slice 2).
enum ChatRole { user, axi }

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
  });

  final String id;
  final ChatRole role;
  final String text;
  final DateTime timestamp;

  @override
  bool operator ==(Object other) =>
      other is ChatMessage &&
      other.id == id &&
      other.role == role &&
      other.text == text &&
      other.timestamp == timestamp;

  @override
  int get hashCode => Object.hash(id, role, text, timestamp);

  @override
  String toString() => 'ChatMessage(id: $id, role: $role, text: $text)';
}
