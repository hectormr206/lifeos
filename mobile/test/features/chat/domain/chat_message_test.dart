// ChatMessage value-equality only (spec mobile-chat).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';

void main() {
  test('ChatMessage value-equality compares id/role/text/timestamp', () {
    final ts = DateTime.utc(2026, 1, 1);
    final a = ChatMessage(id: '1', role: ChatRole.user, text: 'hola', timestamp: ts);
    final b = ChatMessage(id: '1', role: ChatRole.user, text: 'hola', timestamp: ts);
    final c = ChatMessage(id: '1', role: ChatRole.axi, text: 'hola', timestamp: ts);

    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a.hashCode, equals(b.hashCode));
  });
}
