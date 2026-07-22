// ChatMessage value-equality, status/metrics fields, and copyWith
// (spec mobile-chat + SLICE 1 checkmarks/metrics).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifeos/features/chat/domain/chat_message.dart';
import 'package:lifeos/features/local_model/domain/local_llm_engine.dart';

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

  test('status and metrics default to null and take part in equality', () {
    final ts = DateTime.utc(2026, 1, 1);
    final plain = ChatMessage(id: '1', role: ChatRole.user, text: 'hola', timestamp: ts);
    expect(plain.status, isNull);
    expect(plain.metrics, isNull);

    final withStatus = ChatMessage(
      id: '1',
      role: ChatRole.user,
      text: 'hola',
      timestamp: ts,
      status: ChatMessageStatus.sent,
    );
    expect(plain, isNot(equals(withStatus)));
  });

  test('copyWith advances status while preserving the other fields', () {
    final ts = DateTime.utc(2026, 1, 1);
    final sending = ChatMessage(
      id: '1',
      role: ChatRole.user,
      text: 'hola',
      timestamp: ts,
      status: ChatMessageStatus.sending,
    );

    final delivered = sending.copyWith(status: ChatMessageStatus.delivered);

    expect(delivered.status, ChatMessageStatus.delivered);
    expect(delivered.id, '1');
    expect(delivered.text, 'hola');
    expect(delivered.timestamp, ts);
  });

  test('copyWith can attach metrics to an axi message', () {
    final ts = DateTime.utc(2026, 1, 1);
    const metrics = GenerationMetrics(
      totalMs: 1000,
      tokensOut: 20,
      backend: LocalLlmBackend.gpu,
      modelId: 'x',
    );
    final axi = ChatMessage(id: 'a', role: ChatRole.axi, text: 'listo', timestamp: ts);

    expect(axi.copyWith(metrics: metrics).metrics, metrics);
  });
}
